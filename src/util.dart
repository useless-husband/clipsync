import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// 用 CLIPSYNC_DEBUG=1 dart run clipsync.dart … 打開封包層級的日誌。
/// 排「明明同網段卻看不到彼此」時,這比猜快一百倍。
final bool kDebug = Platform.environment['CLIPSYNC_DEBUG'] == '1';

void debugLog(String message) {
  if (kDebug) stdout.writeln('  · $message');
}

/// FNV-1a 32-bit。純粹拿來做「內容指紋」給人看、給日誌去重用,
/// 不是密碼學雜湊(Step 4 談加密時會換成 SHA-256 / HMAC)。
String shortHash(String s) => shortHashBytes(utf8.encode(s));

String shortHashBytes(List<int> bytes) {
  int h = 0x811c9dc5;
  for (final b in bytes) {
    h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

String humanBytes(int n) => _humanBytes(n);

/// 終端機不該被 100KB 的剪貼簿內容洗版,只印前面一小段。
String preview(String s, {int max = 60}) {
  final flat = s.replaceAll('\r\n', '␤').replaceAll('\n', '␤').replaceAll('\t', '␉');
  final head = flat.length <= max ? flat : '${flat.substring(0, max)}…';
  return '$head  (${_humanBytes(utf8.encode(s).length)})';
}

String _humanBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
}

// ── 一個最小的 PNG 產生器 ──────────────────────────────────────────
// 給 --doctor 用:要測「圖片同步」就得有一張真的圖,而且不能靠外部套件、
// 也不能靠平台工具(Windows 上沒有 sips)。PNG 其實很單純:
// 檔案簽章 + IHDR + IDAT(zlib 壓縮的像素) + IEND,每塊後面接一個 CRC32。

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

List<int> _be32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

List<int> _pngChunk(String type, List<int> data) {
  final typed = [...ascii.encode(type), ...data];
  return [..._be32(data.length), ...typed, ..._be32(_crc32(typed))];
}

/// 產生一張 [size]×[size] 的純色 PNG。
Uint8List tinyPng({int size = 8, int r = 220, int g = 80, int b = 140}) {
  final raw = <int>[];
  for (var y = 0; y < size; y++) {
    raw.add(0); // 每一列開頭的 filter type
    for (var x = 0; x < size; x++) {
      raw.addAll([r, g, b]);
    }
  }
  return Uint8List.fromList([
    137, 80, 78, 71, 13, 10, 26, 10, // PNG 簽章
    ..._pngChunk('IHDR', [
      ..._be32(size), ..._be32(size),
      8, 2, 0, 0, 0, // 8-bit、色彩型別 2 (RGB)、無交錯
    ]),
    ..._pngChunk('IDAT', ZLibCodec().encode(raw)),
    ..._pngChunk('IEND', const []),
  ]);
}

String hhmmss([DateTime? t]) {
  final d = t ?? DateTime.now();
  String p(int v) => v.toString().padLeft(2, '0');
  return '${p(d.hour)}:${p(d.minute)}:${p(d.second)}';
}

/// 裝置 ID:比「名字」可靠。兩台電腦都叫 MacBook-Pro 時,靠名字判斷自己
/// 的封包會直接翻車 —— 這是 Step 1 那招「比對名字」的正式版。
///
/// 組成 = 機器碼(存在家目錄,重開機不變) + 名字的短雜湊。
/// 為什麼要加名字?因為在**同一台電腦**開兩個實例自我測試時,兩邊會讀到
/// 同一份機器碼,於是彼此都把對方的心跳當成「自己的回音」丟掉 —— 兩個實例
/// 明明在互相廣播卻永遠看不到對方。加上名字就能區分同機器的不同實例。
Future<String> loadOrCreateInstanceId(String instanceName) async {
  final machineId = await _loadOrCreateMachineId();
  return '$machineId-${shortHash(instanceName).substring(0, 4)}';
}

Future<String> _loadOrCreateMachineId() async {
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.systemTemp.path;
  final dir = Directory('$home${Platform.pathSeparator}.clipsync');
  final file = File('${dir.path}${Platform.pathSeparator}device_id');

  try {
    if (await file.exists()) {
      final id = (await file.readAsString()).trim();
      if (id.isNotEmpty) return id;
    }
    final id = _randomId();
    await dir.create(recursive: true);
    await file.writeAsString(id);
    return id;
  } catch (_) {
    return _randomId(); // 家目錄不可寫也不該讓程式跑不起來
  }
}

String _randomId() {
  final r = Random.secure();
  return List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// 列出本機所有 IPv4 位址,用來:1) 開機時印給使用者看 2) 判斷封包是不是自己發的
Future<List<String>> localIPv4() async {
  try {
    final ifs = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    return [for (final i in ifs) for (final a in i.addresses) a.address];
  } catch (_) {
    return const [];
  }
}
