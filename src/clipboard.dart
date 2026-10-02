// 跨平台剪貼簿存取(文字 / 圖片 / 檔案)。
//
// 純 Dart 沒有內建剪貼簿 API,所以這裡的做法是「呼叫作業系統本來就有的工具」:
//   macOS   → pbpaste/pbcopy(文字)+ osascript(圖片、檔案)
//   Windows → PowerShell 的 Get-Clipboard / System.Windows.Forms.Clipboard
//   Linux   → wl-clipboard(Wayland)或 xclip(X11)
//
// 這層被刻意做成一個抽象類別:之後搬進 Flutter 時,只要多寫一個
// FlutterClipboard implements SystemClipboard,上面所有邏輯一行都不用改。
//
// 效能上的關鍵設計:probe() 只做「輕量探測」,不讀圖片位元組。
// 輪詢每 700ms 跑一次,不能每次都把幾 MB 的圖搬進記憶體。
//
// 韌性上的關鍵設計:**每一個子行程都有逾時**。剪貼簿工具是別人寫的程式,
// 它卡住(X11 selection owner 死鎖、PowerShell 假死…)不該把我們拖下水 ——
// 沒有逾時的話,一次卡住就永遠停止輪詢,同步默默死掉,比當機還難查。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'clip_content.dart';
import 'util.dart';

abstract class SystemClipboard {
  String get backendName;
  bool get supportsImages;
  bool get supportsFiles;

  /// 輕量探測:現在剪貼簿裡是什麼、signature 是什麼。讀不到就回 null。
  Future<ClipSnapshot?> probe();

  /// 真的把圖片位元組讀出來(貴,只在確定變了之後才呼叫)。回傳 PNG。
  Future<Uint8List?> readImageBytes();

  Future<bool> writeText(String text);
  Future<bool> writeImage(Uint8List pngBytes);
  Future<bool> writeFiles(List<String> paths);

  static Future<SystemClipboard> detect() async {
    if (Platform.isMacOS) return MacClipboard();
    if (Platform.isWindows) return WindowsClipboard();
    if (Platform.isLinux) {
      final wayland = Platform.environment['WAYLAND_DISPLAY'] != null;
      if (wayland && await _hasCommand('wl-copy')) return LinuxClipboard.wayland();
      if (await _hasCommand('xclip')) return LinuxClipboard.xclip();
      throw ClipboardUnavailable(
        '找不到剪貼簿工具。請安裝其中一個:\n'
        '  Wayland: sudo apt install wl-clipboard\n'
        '  X11    : sudo apt install xclip',
      );
    }
    throw ClipboardUnavailable('尚未支援此平台:${Platform.operatingSystem}');
  }
}

class ClipboardUnavailable implements Exception {
  final String message;
  ClipboardUnavailable(this.message);
  @override
  String toString() => message;
}

/// ⚠ 一定要明確指定 UTF-8 locale。
///
/// pbpaste / pbcopy 的編碼是**看 locale 決定的**。從終端機執行時,你的 shell
/// 通常已經設好 LANG=…UTF-8,所以一切正常;但用 launchd 開機自動啟動時,
/// 環境變數是乾淨的、**沒有 LANG**,pbpaste 就會改用 Mac Roman 輸出:
///
///   有 LANG: 「中文測試abc」 15 bytes
///   沒 LANG: 「????abc」      7 bytes   ← 資料直接被毀掉
///
/// 而且它不會報錯,只是安靜地把每個中文字換成問號。寫入端(pbcopy)同理。
const Map<String, String> _utf8Env = {
  'LANG': 'en_US.UTF-8',
  'LC_ALL': 'en_US.UTF-8',
  'LC_CTYPE': 'en_US.UTF-8',
};

/// 一般子行程的逾時;圖片操作(轉檔、大圖編碼)放寬。
const Duration _kProcTimeout = Duration(seconds: 10);
const Duration _kImageProcTimeout = Duration(seconds: 30);

/// 暫存檔名帶流水號。之前只用 pid,同一個程序裡兩個並行的剪貼簿操作
/// (兩個 HTTP 請求同時 applyRemote)會搶同一個檔名,互相蓋掉對方的資料。
int _tmpSeq = 0;
File _tempFile(String suffix) => File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}'
    'clipsync_${pid}_${_tmpSeq++}_$suffix');

Future<bool> _hasCommand(String name) async {
  try {
    return (await Process.run('which', [name])).exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// 跑一個指令、拿回原始位元組(圖片要用這個,不能走文字解碼)。
///
/// [waitForOutput] = false 是給「寫入類」指令用的:xclip / wl-copy 會 fork
/// 一個常駐子行程去服務 selection,那個子行程**繼承了 stdout/stderr 的管線
/// 而且永遠不關** —— 等管線 EOF 等於永遠等下去(父行程其實早就正常結束了)。
/// 寫入只需要父行程的結束碼,所以那條路不等輸出、只等 exitCode。
/// 這曾是一個 critical bug:X11 上收到第一則內容,寫入就永久卡死,
/// _applying 永遠是 true,之後連本機的複製都偵測不到了。
Future<Uint8List?> _runBytes(
  List<String> cmd, {
  List<int>? stdinBytes,
  Duration timeout = _kProcTimeout,
  bool waitForOutput = true,
}) async {
  Process? p;
  try {
    p = await Process.start(cmd.first, cmd.sublist(1),
        environment: _utf8Env, includeParentEnvironment: true);
    if (stdinBytes != null) p.stdin.add(stdinBytes);
    // close() 會把緩衝的資料 flush 完;對方已死時會丟 EPIPE → 吞掉,
    // 結果交給 exitCode 判斷。不 await 它,免得它本身卡住。
    p.stdin.close().then((_) {}, onError: (_) {});

    final out = <int>[];
    final outDone = p.stdout.forEach(out.addAll);
    final errDone = p.stderr.drain<void>();

    if (waitForOutput) {
      await Future.wait([outDone, errDone]).timeout(timeout);
      final code = await p.exitCode.timeout(timeout);
      if (code != 0) return null;
      return Uint8List.fromList(out);
    } else {
      outDone.ignore();
      errDone.ignore();
      final code = await p.exitCode.timeout(timeout);
      return code == 0 ? Uint8List.fromList(out) : null;
    }
  } on TimeoutException {
    p?.kill(ProcessSignal.sigkill);
    return null;
  } catch (_) {
    p?.kill(ProcessSignal.sigkill);
    return null;
  }
}

Future<String?> _runText(List<String> cmd,
    {List<int>? stdinBytes,
    Duration timeout = _kProcTimeout,
    bool waitForOutput = true}) async {
  final bytes = await _runBytes(cmd,
      stdinBytes: stdinBytes, timeout: timeout, waitForOutput: waitForOutput);
  if (bytes == null) return null;
  try {
    return utf8.decode(bytes, allowMalformed: true);
  } catch (_) {
    return null;
  }
}

/// U+FEFF(BOM)出現在字串開頭時砍掉。注意 String.trim() 砍不掉它。
String _stripBom(String s) => s.startsWith('﻿') ? s.substring(1) : s;

// ═══════════════════════════════ macOS ═══════════════════════════════

class MacClipboard extends SystemClipboard {
  @override
  String get backendName => 'pbpaste/pbcopy + osascript';
  @override
  bool get supportsImages => true;
  @override
  bool get supportsFiles => true;

  /// `clipboard info` 會回傳剪貼簿裡所有格式與各自的位元組數,例如:
  ///   文字   → `string, 21, «class utf8», 21`
  ///   圖片   → `«class PNGf», 1104316, «class TIFF», 2000000`
  ///   單檔   → `«class furl», 108`
  ///   多檔   → `list, 264, list, 264`
  /// 對圖片來說,這串字裡的位元組數就是現成的 signature —— 不用把圖讀出來
  /// 就知道換了沒。這是整個輪詢能維持在 ~50ms 的原因。
  @override
  Future<ClipSnapshot?> probe() async {
    final info = await _osascript('return (clipboard info)');
    if (info == null) return null;
    final flat = info.trim();
    if (flat.isEmpty) return null;

    if (flat.contains('furl') || flat.startsWith('list,')) {
      final paths = await _readFilePaths();
      final refs = <ClipFileRef>[];
      for (final path in paths) {
        final ref = ClipFileRef.fromPath(path);
        if (ref != null) refs.add(ref);
      }
      if (refs.isNotEmpty) {
        return ClipSnapshot(
          kind: ClipKind.files,
          signature: 'F:${refs.map((f) => '${f.path}:${f.size}').join('|')}',
          files: refs,
        );
      }
      if (paths.isNotEmpty) {
        // 剪貼簿裡確實是檔案參照,但沒有一個是可傳的普通檔案(通常是
        // 資料夾)。以前這裡會往下掉、把 pbpaste 讀到的「資料夾名稱」
        // 當成文字同步出去 —— 對方貼上一個莫名其妙的名字。
        // 資料夾不支援就明白地不支援,不要偷渡成文字。
        return null;
      }
      // 連路徑都讀不出來(furl 解析失敗)才往下當一般內容處理。
    }

    // 文字和圖片的 flavor 常常**同時存在**:Excel 複製儲存格會同時放
    // 表格截圖和純文字;瀏覽器複製圖片會同時放圖和網址。誰排在
    // clipboard info 前面,就代表來源 App 認為誰是主要格式 —— 跟著它走,
    // 而不是永遠圖片優先(那會把 Excel 表格同步成一張截圖)。
    final imgIdx = _firstIndexOf(flat, const ['PNGf', 'TIFF']);
    final textIdx = _firstIndexOf(flat, const ['string', 'utf8', 'ut16']);

    if (imgIdx >= 0 && (textIdx < 0 || imgIdx < textIdx)) {
      return ClipSnapshot(kind: ClipKind.image, signature: 'I:$flat');
    }

    final text = await _runText(const ['pbpaste']);
    if (text == null || text.isEmpty) {
      if (imgIdx >= 0) {
        return ClipSnapshot(kind: ClipKind.image, signature: 'I:$flat');
      }
      return null;
    }
    return ClipSnapshot(
      kind: ClipKind.text,
      signature: 'T:${shortHash(text)}:${text.length}',
      text: text,
    );
  }

  static int _firstIndexOf(String s, List<String> needles) {
    var best = -1;
    for (final n in needles) {
      final i = s.indexOf(n);
      if (i >= 0 && (best < 0 || i < best)) best = i;
    }
    return best;
  }

  /// 讀出剪貼簿裡的檔案路徑(不管檔案是否存在、是不是資料夾)。
  Future<List<String>> _readFilePaths() async {
    // 單檔是 «class furl»,多檔是 list —— 兩種都要接。
    const script = '''
try
    set out to ""
    set L to (the clipboard as list)
    repeat with f in L
        set out to out & (POSIX path of (f as «class furl»)) & linefeed
    end repeat
    return out
on error
    try
        return POSIX path of (the clipboard as «class furl»)
    on error
        return ""
    end try
end try''';
    final result = await _osascript(script);
    if (result == null) return const [];
    return [
      for (final line in const LineSplitter().convert(result))
        if (line.trim().isNotEmpty) line.trim(),
    ];
  }

  @override
  Future<Uint8List?> readImageBytes() async {
    // 先試 PNG。多數情況下剪貼簿裡就有 PNGf,直接拿最快。
    final png = await _readClipboardAs('«class PNGf»', 'png');
    if (png != null) return png;

    // 拿不到 PNG 就退而求其次抓 TIFF,再用 sips 轉成 PNG。
    // Preview 以及不少舊 Mac App 複製圖片時只放 TIFF、不放 PNGf。
    final tiff = await _readClipboardAs('«class TIFF»', 'tiff');
    if (tiff == null) return null;
    return _tiffToPng(tiff);
  }

  Future<Uint8List?> _readClipboardAs(String klass, String suffix) async {
    final tmp = _tempFile('read.$suffix');
    final ok = await _osascript('''
set fp to open for access POSIX file ${_asStr(tmp.path)} with write permission
try
    set imgData to the clipboard as $klass
    set eof fp to 0
    write imgData to fp
    close access fp
    return "ok"
on error e
    try
        close access fp
    end try
    return "err: " & e
end try''', timeout: _kImageProcTimeout);
    try {
      if (ok == null || !ok.trim().startsWith('ok')) return null;
      if (!await tmp.exists()) return null;
      final bytes = await tmp.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  /// sips 是 macOS 內建的圖片轉檔工具,不用額外安裝。
  Future<Uint8List?> _tiffToPng(Uint8List tiff) async {
    final src = _tempFile('conv.tiff');
    final dst = _tempFile('conv.png');
    try {
      await src.writeAsBytes(tiff, flush: true);
      final r = await _runBytes(
          ['sips', '-s', 'format', 'png', src.path, '--out', dst.path],
          timeout: _kImageProcTimeout);
      if (r == null || !await dst.exists()) return null;
      return await dst.readAsBytes();
    } catch (_) {
      return null;
    } finally {
      for (final f in [src, dst]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }

  @override
  Future<bool> writeText(String text) async =>
      await _runBytes(const ['pbcopy'],
          stdinBytes: utf8.encode(text), waitForOutput: false) !=
      null;

  @override
  Future<bool> writeImage(Uint8List pngBytes) async {
    final tmp = _tempFile('write.png');
    try {
      await tmp.writeAsBytes(pngBytes, flush: true);
      final r = await _osascript(
          'set the clipboard to (read (POSIX file ${_asStr(tmp.path)}) as «class PNGf»)',
          timeout: _kImageProcTimeout);
      return r != null;
    } catch (_) {
      return false;
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  @override
  Future<bool> writeFiles(List<String> paths) async {
    if (paths.isEmpty) return false;
    final items = paths.map((p) => 'POSIX file ${_asStr(p)}').join(', ');
    final r = await _osascript('set the clipboard to {$items}');
    return r != null;
  }

  Future<String?> _osascript(String script,
      {Duration timeout = _kProcTimeout}) async {
    Process? p;
    try {
      p = await Process.start('osascript', const ['-'],
          environment: _utf8Env, includeParentEnvironment: true);
      p.stdin.add(utf8.encode(script));
      p.stdin.close().then((_) {}, onError: (_) {});
      final out = <int>[];
      final outDone = p.stdout.forEach(out.addAll);
      final errDone = p.stderr.drain<void>();
      await Future.wait([outDone, errDone]).timeout(timeout);
      final code = await p.exitCode.timeout(timeout);
      if (code != 0) return null;
      return utf8.decode(out, allowMalformed: true);
    } on TimeoutException {
      p?.kill(ProcessSignal.sigkill);
      return null;
    } catch (_) {
      p?.kill(ProcessSignal.sigkill);
      return null;
    }
  }

  /// AppleScript 字串跳脫。檔名裡有引號或反斜線時不處理會直接讓腳本語法錯誤。
  static String _asStr(String s) =>
      '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
}

// ═══════════════════════════════ Windows ═══════════════════════════════

/// ⚠ 這一段沒有完整在 Windows 上實測過(開發機是 macOS)。
class WindowsClipboard extends SystemClipboard {
  @override
  String get backendName => 'PowerShell Get-Clipboard / Set-Clipboard';
  @override
  bool get supportsImages => true;
  @override
  bool get supportsFiles => true;

  @override
  Future<ClipSnapshot?> probe() async {
    // 一次 PowerShell 啟動就把三種格式都查完 —— PowerShell 啟動成本高,
    // 不能像 macOS 那樣分成多次呼叫。
    //
    // 注意兩件事:
    //  1. 編碼必須是「不帶 BOM」的 UTF-8(帶 BOM 的話第一行變 "﻿TEXT",
    //     而 Dart 的 trim() 砍不掉 U+FEFF,整個 probe 永遠 null)。
    //  2. 熱路徑不 Add-Type:Get-Clipboard 這個 cmdlet 自己就支援 -Format,
    //     每 1.5 秒載入一次 WinForms 會把機器拖垮(實測連心跳都發不出來)。
    //  3. 不在 if 條件裡做賦值(`elseif ($img = ...)`)—— 那在 PowerShell
    //     是合法語法但極易誤讀,分開寫最保險。
    const script = r'''
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$files = Get-Clipboard -Format FileDropList
if ($files -and $files.Count -gt 0) {
    [Console]::Out.Write("FILES`n")
    foreach ($f in $files) { [Console]::Out.Write($f.FullName + "`n") }
} else {
    $img = Get-Clipboard -Format Image
    if ($null -ne $img) {
        [Console]::Out.Write("IMAGE " + $img.Width + "x" + $img.Height + "`n")
    } else {
        $t = Get-Clipboard -Raw
        if ($null -ne $t -and $t.Length -gt 0) {
            [Console]::Out.Write("TEXT`n")
            [Console]::Out.Write($t)
        } else {
            [Console]::Out.Write("EMPTY`n")
        }
    }
}''';
    final out = await _ps(script);
    if (out == null) return null;

    final nl = out.indexOf('\n');
    if (nl < 0) {
      debugLog('probe: 輸出沒有換行,拿到 ${out.length} 個字元');
      return null;
    }
    final head = _stripBom(out.substring(0, nl)).trim();
    final rest = out.substring(nl + 1);
    debugLog('probe: head="$head" rest=${rest.length} 字元');

    if (head == 'FILES') {
      final refs = <ClipFileRef>[];
      for (final line in const LineSplitter().convert(rest)) {
        final p = line.trim();
        if (p.isEmpty) continue;
        final ref = ClipFileRef.fromPath(p);
        if (ref != null) refs.add(ref);
      }
      if (refs.isEmpty) return null; // 全是資料夾 → 不支援,與 macOS 行為一致
      return ClipSnapshot(
        kind: ClipKind.files,
        signature: 'F:${refs.map((f) => '${f.path}:${f.size}').join('|')}',
        files: refs,
      );
    }

    if (head.startsWith('IMAGE')) {
      // ⚠ 已知弱點:這裡只拿得到寬x高當 signature(README 有記載)。
      return ClipSnapshot(kind: ClipKind.image, signature: 'I:$head');
    }

    if (head == 'TEXT') {
      if (rest.isEmpty) return null;
      return ClipSnapshot(
        kind: ClipKind.text,
        signature: 'T:${shortHash(rest)}:${rest.length}',
        text: rest,
      );
    }
    return null;
  }

  @override
  Future<Uint8List?> readImageBytes() async {
    final tmp = _tempFile('read.png');
    final script = '''
Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null
if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
    \$img = [System.Windows.Forms.Clipboard]::GetImage()
    \$img.Save(${_psStr(tmp.path)}, [System.Drawing.Imaging.ImageFormat]::Png)
}''';
    try {
      await _ps(script, timeout: _kImageProcTimeout);
      if (!await tmp.exists()) return null;
      final bytes = await tmp.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  @override
  Future<bool> writeText(String text) async {
    // 不走 stdin:PowerShell 讀 stdin 的編碼行為在各版本不一致。
    // 先寫成 UTF-8 暫存檔,再叫 PowerShell 用明確編碼讀回來,最穩。
    final tmp = _tempFile('write.txt');
    try {
      await tmp.writeAsString(text, encoding: utf8, flush: true);
      final r = await _ps(
          'Set-Clipboard -Value ([IO.File]::ReadAllText(${_psStr(tmp.path)}, [Text.Encoding]::UTF8))');
      return r != null;
    } catch (_) {
      return false;
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  @override
  Future<bool> writeImage(Uint8List pngBytes) async {
    final tmp = _tempFile('write.png');
    try {
      await tmp.writeAsBytes(pngBytes, flush: true);
      // SetDataObject 第二個參數 $true = 離開這個程序後仍留在剪貼簿。
      final r = await _ps('''
Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null
\$bytes = [IO.File]::ReadAllBytes(${_psStr(tmp.path)})
\$ms = New-Object System.IO.MemoryStream(,\$bytes)
\$img = [System.Drawing.Image]::FromStream(\$ms)
[System.Windows.Forms.Clipboard]::SetDataObject(\$img, \$true)''',
          timeout: _kImageProcTimeout);
      return r != null;
    } catch (_) {
      return false;
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  @override
  Future<bool> writeFiles(List<String> paths) async {
    if (paths.isEmpty) return false;
    // 路徑清單走暫存檔,不塞進指令字串:-EncodedCommand 的長度上限約 32K,
    // 複製一百多個檔案就會爆掉;走檔案就沒有上限問題,編碼也單純。
    final tmp = _tempFile('files.txt');
    try {
      await tmp.writeAsString(paths.join('\r\n'), encoding: utf8, flush: true);
      final r = await _ps('''
Add-Type -AssemblyName System.Windows.Forms | Out-Null
\$col = New-Object System.Collections.Specialized.StringCollection
Get-Content -LiteralPath ${_psStr(tmp.path)} -Encoding UTF8 | ForEach-Object {
    if (\$_.Length -gt 0) { [void]\$col.Add(\$_) }
}
if (\$col.Count -gt 0) {
    \$dobj = New-Object System.Windows.Forms.DataObject
    \$dobj.SetFileDropList(\$col)
    [System.Windows.Forms.Clipboard]::SetDataObject(\$dobj, \$true)
}''');
      return r != null;
    } catch (_) {
      return false;
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  /// 用 -EncodedCommand(base64 UTF-16LE)傳腳本,徹底避開引號與換行的跳脫問題。
  /// -STA 是必要的:剪貼簿 API 需要單執行緒 apartment 模式。
  Future<String?> _ps(String script, {Duration timeout = _kProcTimeout}) async {
    Process? p;
    try {
      p = await Process.start(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-STA', '-EncodedCommand', _encode(script)],
      );
      p.stdin.close().then((_) {}, onError: (_) {});
      final out = <int>[];
      final err = <int>[];
      final outDone = p.stdout.forEach(out.addAll);
      final errDone = p.stderr.forEach(err.addAll);
      await Future.wait([outDone, errDone]).timeout(timeout);
      final code = await p.exitCode.timeout(timeout);
      if (code != 0) {
        // 這個 stderr 是 Windows 上排錯最有用的東西,不要默默吞掉。
        // 用 allowMalformed:錯誤訊息可能是 OEM 編碼,嚴格解碼會再炸一次。
        debugLog('PowerShell 失敗 exit=$code: '
            '${utf8.decode(err, allowMalformed: true).trim().replaceAll('\n', ' ')}');
        return null;
      }
      return _stripBom(utf8.decode(out, allowMalformed: true));
    } on TimeoutException {
      p?.kill(ProcessSignal.sigkill);
      debugLog('PowerShell 逾時(${timeout.inSeconds}s),已強制結束');
      return null;
    } catch (e) {
      p?.kill(ProcessSignal.sigkill);
      debugLog('PowerShell 無法執行:$e');
      return null;
    }
  }

  static String _encode(String script) {
    final bytes = <int>[];
    for (final u in script.codeUnits) {
      bytes.add(u & 0xFF);
      bytes.add((u >> 8) & 0xFF); // UTF-16LE
    }
    return base64.encode(bytes);
  }

  /// PowerShell 單引號字串:裡面的單引號要寫成兩個。
  static String _psStr(String s) => "'${s.replaceAll("'", "''")}'";
}

// ═══════════════════════════════ Linux ═══════════════════════════════

/// ⚠ 這一段沒有實機測試過。
class LinuxClipboard extends SystemClipboard {
  LinuxClipboard._(this._isWayland);
  factory LinuxClipboard.wayland() => LinuxClipboard._(true);
  factory LinuxClipboard.xclip() => LinuxClipboard._(false);

  final bool _isWayland;

  @override
  String get backendName => _isWayland ? 'wl-clipboard (Wayland)' : 'xclip (X11)';
  @override
  bool get supportsImages => true;
  @override
  bool get supportsFiles => true;

  List<String> get _listTypes => _isWayland
      ? const ['wl-paste', '--list-types']
      : const ['xclip', '-selection', 'clipboard', '-t', 'TARGETS', '-o'];

  List<String> _readAs(String mime) => _isWayland
      ? ['wl-paste', '--no-newline', '-t', mime]
      : ['xclip', '-selection', 'clipboard', '-t', mime, '-o'];

  List<String> _writeAs(String mime) => _isWayland
      ? ['wl-copy', '-t', mime]
      : ['xclip', '-selection', 'clipboard', '-t', mime, '-i'];

  /// 讀文字。X11 上**不能**指定 -t text/plain:xterm、urxvt 這些老牌程式
  /// 只提供 UTF8_STRING/STRING,不提供 text/plain,指定了就永遠讀不到。
  /// 不帶 -t 的話 xclip 會自己退回標準的文字 target,兩種來源都吃得到。
  Future<String?> _readText() async {
    if (_isWayland) {
      return _runText(const ['wl-paste', '--no-newline']);
    }
    return await _runText(const ['xclip', '-selection', 'clipboard', '-o']) ??
        await _runText(const ['xclip', '-selection', 'clipboard', '-t', 'text/plain', '-o']);
  }

  @override
  Future<ClipSnapshot?> probe() async {
    final types = (await _runText(_listTypes))?.toLowerCase() ?? '';

    if (types.contains('text/uri-list')) {
      final raw = await _runText(_readAs('text/uri-list'));
      if (raw != null) {
        final refs = <ClipFileRef>[];
        for (final line in const LineSplitter().convert(raw)) {
          var p = line.trim();
          if (p.isEmpty || p.startsWith('#')) continue;
          if (p.startsWith('file://')) {
            // toFilePath 會處理 %-解碼與主機名;格式爛掉就跳過這一行,
            // 不要讓一個壞 URI 把整個 probe 炸成例外。
            try {
              p = Uri.parse(p).toFilePath();
            } catch (_) {
              continue;
            }
          }
          final ref = ClipFileRef.fromPath(p);
          if (ref != null) refs.add(ref);
        }
        if (refs.isNotEmpty) {
          return ClipSnapshot(
            kind: ClipKind.files,
            signature: 'F:${refs.map((f) => '${f.path}:${f.size}').join('|')}',
            files: refs,
          );
        }
      }
    }

    if (types.contains('image/png')) {
      // Linux 的剪貼簿工具是原生程式、啟動很快,直接讀出來雜湊沒問題。
      final bytes = await _runBytes(_readAs('image/png'));
      if (bytes != null && bytes.isNotEmpty) {
        return ClipSnapshot(
          kind: ClipKind.image,
          signature: 'I:${bytes.length}:${shortHashBytes(bytes)}',
        );
      }
    }

    // 只有圖片格式、沒有任何文字格式時,不要硬讀文字(會拿到二進位垃圾)。
    if (types.contains('image/') && !types.contains('text') &&
        !types.contains('string')) {
      return null;
    }

    final text = await _readText();
    if (text == null || text.isEmpty) return null;
    return ClipSnapshot(
      kind: ClipKind.text,
      signature: 'T:${shortHash(text)}:${text.length}',
      text: text,
    );
  }

  @override
  Future<Uint8List?> readImageBytes() =>
      _runBytes(_readAs('image/png'), timeout: _kImageProcTimeout);

  /// 寫入類指令一律 waitForOutput:false —— xclip 和(部分版本的)wl-copy
  /// 會 fork 常駐子行程服務 selection,等它的管線 EOF 會永遠等下去。
  @override
  Future<bool> writeText(String text) async {
    final cmd = _isWayland
        ? const ['wl-copy']
        : const ['xclip', '-selection', 'clipboard', '-i'];
    // 不帶 -t:xclip 會同時提供 UTF8_STRING/STRING/TEXT,這才是別的 App
    // 貼上時真正會要求的 target;只提供 text/plain 的話很多 App 貼不到。
    return await _runBytes(cmd,
            stdinBytes: utf8.encode(text), waitForOutput: false) !=
        null;
  }

  @override
  Future<bool> writeImage(Uint8List pngBytes) async =>
      await _runBytes(_writeAs('image/png'),
          stdinBytes: pngBytes,
          timeout: _kImageProcTimeout,
          waitForOutput: false) !=
      null;

  @override
  Future<bool> writeFiles(List<String> paths) async {
    // Uri.file() 做正規的 file:// URI 編碼(# ? 空白 % 都會處理)。
    // 已知限制:GNOME 檔案管理員的貼上要 x-special/gnome-copied-files
    // 這個私有 target,xclip 一次只能服務一種 target,先不支援。
    final uris = paths.map((p) => Uri.file(p).toString()).join('\n');
    return await _runBytes(_writeAs('text/uri-list'),
            stdinBytes: utf8.encode(uris), waitForOutput: false) !=
        null;
  }
}
