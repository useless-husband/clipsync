// ClipSync — Step 3:區網剪貼簿同步(文字 / 圖片 / 檔案),純 Dart。
//
//   dart run clipsync.dart Alice      # 電腦 A
//   dart run clipsync.dart Bob        # 電腦 B
//
// 在 A 複製文字、截圖、或在檔案總管複製檔案 → B 直接 Ctrl/Cmd+V 貼上。
//
// 演進:
//   Step 1  UDP 廣播找人 + 手動打字互傳                (step1_discovery.dart)
//   Step 2  自動偵測剪貼簿變化 + 寫入 + 內容改走 HTTP
//   Step 3  圖片與檔案(HTTP body 改成原始二進位)      ← 現在

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'src/clip_content.dart';
import 'src/clipboard.dart';
import 'src/config.dart';
import 'src/discovery.dart';
import 'src/message.dart';
import 'src/peer.dart';
import 'src/transport.dart';
import 'src/util.dart';
import 'src/watcher.dart';
import 'src/webui.dart';

late final String myName;
late final String myDeviceId;
late final SystemClipboard clipboard;
late final ClipboardWatcher watcher;
late final PeerRegistry peers;
late final Discovery discovery;
late final ContentServer server;
late final WebUi webUi;
late final DateTime _startedAt;
final ContentSender sender = ContentSender();
final Random _rng = Random.secure();

int _seq = 0;
int _sentCount = 0;
int _recvCount = 0;
String? _lastBroadcastSig;
bool _acceptFromAnyone = false;
bool _filesEnabled = true;
late String _inboxDir;

/// 每台裝置「最後一次成功套用」的訊息時間戳與序號。
///
/// 沒有這個檢查的話,舊訊息可以蓋掉新訊息:A 連續複製 T1、T2,T1 的連線
/// 剛好卡在重送(Wi-Fi 掉 SYN 很常見),T2 先到先套用 —— 然後遲到的 T1
/// 抵達,把 B 的剪貼簿**倒退回舊內容**,而且回音防護還會把這個舊狀態
/// 鎖住(簽章已記錄,不會回傳修正)。比對時間戳,舊的直接丟。
final Map<String, (int, int)> _lastApplied = {}; // deviceId → (sentAtMs, seq)

bool _isStale(ClipMeta meta) {
  final last = _lastApplied[meta.fromDeviceId];
  if (last == null) return false;
  if (meta.sentAtMs < last.$1) return true;
  if (meta.sentAtMs == last.$1 && meta.seq <= last.$2) return true;
  return false;
}

Future<void> main(List<String> args) async {
  // 最後一道保險:背景服務不該因為一個沒接到的非同步錯誤就整個死掉。
  // 開機自動啟動時網路還沒好、Wi-Fi 切換、對方中途斷線…… 這些都可能冒出
  // 預期外的例外。記下來、繼續跑,比安靜地消失好得多。
  await runZonedGuarded(() => _main(args), (error, stack) {
    stdout.writeln('${hhmmss()}  ⚠ 未預期的錯誤(已忽略,程式繼續執行):$error');
    if (kDebug) stdout.writeln(stack.toString());
  });
}

Future<void> _main(List<String> args) async {
  _startedAt = DateTime.now();
  final opts = _Options.parse(args);
  if (opts.showHelp) {
    _printHelp();
    return;
  }
  if (opts.doctor) {
    await _runDoctor();
    return;
  }

  // 啟動器可能傳進空字串(例如 Windows 的 .bat 讀不到輸入時),
  // 空名字在對方的裝置清單上會顯示成一片空白,完全認不出是誰。
  final requested = opts.name?.trim() ?? '';
  myName = requested.isEmpty ? Platform.localHostname : requested;
  myDeviceId = await loadOrCreateInstanceId(myName);
  _acceptFromAnyone = opts.acceptFromAnyone;
  _filesEnabled = !opts.noFiles;
  _inboxDir = opts.inboxDir ?? defaultInboxDir();

  // ── 1. 剪貼簿後端 ───────────────────────────────────────────────
  try {
    clipboard = await SystemClipboard.detect();
  } on ClipboardUnavailable catch (e) {
    stderr.writeln('✗ $e');
    exitCode = 1;
    return;
  }

  peers = PeerRegistry()
    ..onFound = (p) {
      _log('✓ 發現裝置:${p.name} (${p.ip}:${p.contentPort}, ${p.platform})');
    }
    ..onLost = (p) {
      _log('✗ 裝置離線:${p.name} (${p.ip})');
    }
    ..onChanged = (p, what) {
      _log('↻ ${p.name} $what');
    };

  // ── 2. 內容伺服器(先啟動,才知道最後拿到哪個 port 可以廣播出去)──
  server = ContentServer(
    onTextOrImage: _onRemoteTextOrImage,
    onFilesComplete: _onRemoteFiles,
    isAllowed: (ip) =>
        _acceptFromAnyone || peers.hasIp(ip) || ip == '127.0.0.1' || ip == '::1',
    inboxDir: _inboxDir,
    maxTransferBytes: opts.maxTransferBytes,
    acceptFiles: _filesEnabled,
  )..onLog = _log;
  await server.start(preferredPort: opts.contentPort);

  // ── 3. 剪貼簿監看 ───────────────────────────────────────────────
  // --paused 只暫停「這一個程序」(session),不寫全域旗標檔。
  // 之前寫旗標檔的版本會把這台電腦上所有 ClipSync(含背景服務)一起
  // 暫停,而且旗標檔重開機還在 —— 使用者只是想這次先不同步而已。
  watcher = ClipboardWatcher(clipboard, interval: opts.pollInterval)
    ..onLocalChange = _onLocalClipboardChange
    ..onError = (r) {
      _log('⚠ $r');
    }
    ..onPauseChanged = (p) {
      _log(p ? '⏸ 偵測到暫停旗標,已暫停同步。' : '▶ 暫停旗標已移除,恢復同步。');
    }
    ..sessionPaused = opts.startPaused;
  await watcher.start();

  // ── 4. UDP 探索 ─────────────────────────────────────────────────
  discovery = Discovery(
    myDeviceId: myDeviceId,
    myName: myName,
    peers: peers,
    contentPortProvider: () => server.port,
  )..onLog = _log;
  await discovery.start();

  // ── 4b. 主動確認生死 ────────────────────────────────────────────
  // 廣播心跳掉光了不代表對方不在。太久沒聽到消息的裝置,先用 TCP 敲一下
  // /ping 再決定要不要把它從清單裡拿掉 —— 清單一旦少了對方,他推內容過來
  // 就會被當成陌生 IP 擋掉,使用者只會看到莫名其妙的「同步失敗」。
  //
  // 兩個防競態的細節:_livenessBusy 擋 Timer 的重入(ping 有 3 秒逾時,
  // 一輪拖太久時下一輪會疊上來);pingInFlight 讓 sweep 先別動正在確認
  // 中的裝置(否則 sweep 移除後 ping 才成功,更新到的是孤兒物件)。
  var livenessBusy = false;
  Timer.periodic(const Duration(seconds: 5), (_) async {
    if (livenessBusy) return;
    livenessBusy = true;
    try {
      final now = DateTime.now();
      for (final p in peers.all.toList()) {
        final silent = now.difference(p.lastSeen);
        if (silent < const Duration(seconds: 12) || silent > kPeerTimeout) {
          continue;
        }
        p.pingInFlight = true;
        try {
          if (await sender.ping(p)) {
            p.lastSeen = DateTime.now();
            debugLog('${p.name} 廣播沒收到,但 TCP ping 得通 → 維持在線');
          }
        } finally {
          p.pingInFlight = false;
        }
      }
    } finally {
      livenessBusy = false;
    }
  });

  // ── 4c. 網頁控制台 ──────────────────────────────────────────────
  // 背景執行時沒有終端機,這一頁就是使用者「看得到、按得到」的介面。
  // 只綁 127.0.0.1,區網上其他電腦碰不到(細節見 src/webui.dart 檔頭)。
  webUi = WebUi(
    status: _statusForUi,
    events: () => _recent,
    setPaused: (v) async {
      await ClipboardWatcher.setPaused(v);
      watcher.sessionPaused = v;
      _log(v
          ? '⏸ 已從控制台暫停同步(這台電腦上所有 ClipSync 一起暫停)'
          : '▶ 已從控制台恢復同步');
    },
    sendText: _sendTextManually,
    pushClipboard: () async {
      final cur = watcher.current;
      if (cur == null) return '剪貼簿是空的(或是不支援的格式),沒有東西可以推';
      _lastBroadcastSig = null;
      await _onLocalClipboardChange(cur, force: true);
      return '已重新推送:${cur.describe()}(結果看活動記錄)';
    },
    openInbox: _openInboxFolder,
  )..onLog = _log;
  await webUi.start();

  await _printBanner(opts);

  // ── 5. 鍵盤指令 ─────────────────────────────────────────────────
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen(_onCommand);

  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('');
    await _shutdown();
  });
}

// ───────────────────────────── 送出 ─────────────────────────────

/// 剛收到的檔案就躺在 _inboxDir 裡。如果不擋,會出事:
///
/// 文字和圖片是「冪等」的 —— A 複製 X,B 寫入 X,兩邊的 signature 一樣,
/// 迴圈自然停。但**檔案不是**:B 把檔案存到自己的 Downloads/ClipSync,
/// 路徑跟 A 給的完全不同,於是 B 的剪貼簿看起來就像「使用者複製了新檔案」。
/// 在同一台電腦開兩個實例自我測試時,這會變成檔案不斷增生的無限迴圈
/// (f1.txt → f1 (2).txt → f1 (3).txt …)。
///
/// 規則很單純:自動偵測到的檔案如果全都在收件匣裡,就不要再送出去。
/// 真的想轉送的話,用 /push 明確指定。
bool _allInsideInbox(List<ClipFileRef> files) {
  if (files.isEmpty) return false;
  final inbox = _inboxDir.endsWith(Platform.pathSeparator)
      ? _inboxDir
      : '$_inboxDir${Platform.pathSeparator}';
  return files.every((f) => f.path.startsWith(inbox));
}

/// 使用者在本機複製了東西 → 推給所有已知裝置。
Future<void> _onLocalClipboardChange(ClipSnapshot snap, {bool force = false}) async {
  // 回音防護第 3 層:同一份內容不重複廣播。
  // 就算前兩層都失手,迴圈也會在這裡停下來。
  if (snap.signature == _lastBroadcastSig) return;
  _lastBroadcastSig = snap.signature;

  switch (snap.kind) {
    case ClipKind.text:
      final text = snap.text ?? '';
      final bytes = utf8.encode(text);
      if (bytes.length > kMaxTextBytes) {
        _log('⚠ 文字 ${humanBytes(bytes.length)} 超過上限,不同步');
        return;
      }
      _log('📤 複製到文字:${preview(text)}');
      await _broadcastBytes(ClipKind.text, snap.signature, bytes, 'text/plain');

    case ClipKind.image:
      var png = await clipboard.readImageBytes();
      if (png == null || png.isEmpty) {
        // 可能只是瞬態失敗(讀取的瞬間剪貼簿剛好被改),小睡一下重試一次。
        await Future<void>.delayed(const Duration(milliseconds: 300));
        png = await clipboard.readImageBytes();
      }
      if (png == null || png.isEmpty) {
        _log('⚠ 偵測到圖片但讀不出來(剪貼簿可能剛好又被改掉了),跳過這次');
        // 把「已廣播」記錄退掉:不退的話,這張圖之後用 /push 也送不出去 ——
        // 簽章已經被記成「送過了」,但其實一個位元組都沒送出去。
        _lastBroadcastSig = null;
        return;
      }
      if (png.length > kMaxImageBytes) {
        _log('⚠ 圖片 ${humanBytes(png.length)} 超過上限,不同步');
        return;
      }
      _log('📤 複製到圖片:${humanBytes(png.length)}');
      await _broadcastBytes(ClipKind.image, snap.signature, png, 'image/png');

    case ClipKind.files:
      if (!_filesEnabled) return;
      if (!force && _allInsideInbox(snap.files)) {
        _log('   (剪貼簿裡是剛收到的檔案,不再送回去。要轉送請用 /push)');
        return;
      }
      await _broadcastFiles(snap);
  }
}

/// 挑出「版本合得來」的裝置。
///
/// 沒有這一關的話,區網上只要還有一台跑舊版的機器,每次複製都會噴一次
/// 「送不到 xxx:HTTP 500」—— 使用者只會覺得程式壞了,不會知道是版本不合。
List<Peer> _compatibleTargets() {
  final ok = <Peer>[];
  for (final p in peers.all) {
    if (p.isCompatible) {
      ok.add(p);
    } else if (!p.versionWarned) {
      p.versionWarned = true;
      _log('⚠ ${p.name} (${p.ip}) 跑的是舊版 ClipSync(協定 v${p.protocolVersion},'
          '本機是 v$kProtocolVersion),不會同步給它。');
      _log('  └ 請把整個 ClipSync 資料夾重新複製過去,兩邊版本要一致。');
    }
  }
  return ok;
}

/// 回傳成功送達的裝置數(0 = 一台都沒送到)。
Future<int> _broadcastBytes(
    ClipKind kind, String signature, List<int> body, String mime) async {
  final targets = _compatibleTargets();
  if (targets.isEmpty) {
    _log('   (沒有可同步的裝置,這次不送)');
    return 0;
  }
  final meta = ClipMeta(
    kind: kind,
    fromName: myName,
    fromDeviceId: myDeviceId,
    signature: signature,
    seq: ++_seq,
    sentAtMs: DateTime.now().millisecondsSinceEpoch,
    mime: mime,
  );

  final results =
      await Future.wait(targets.map((p) => sender.sendBytes(p, meta, body)));
  return _reportSendResults(targets, results);
}

Future<void> _broadcastFiles(ClipSnapshot snap) async {
  final targets = _compatibleTargets();
  if (targets.isEmpty) {
    _log('   (沒有可同步的裝置,這次不送)');
    return;
  }
  final files = snap.files;
  final names = files.map((f) => f.name).join('、');
  _log('📤 複製到 ${files.length} 個檔案(共 ${humanBytes(snap.totalFileBytes)}):$names');

  final oversized = files.where((f) => f.size > kMaxFileBytes).toList();
  if (oversized.isNotEmpty) {
    _log('   ⚠ 這些檔案超過單檔上限 ${humanBytes(kMaxFileBytes)},略過:'
        '${oversized.map((f) => f.name).join('、')}');
  }
  final sendable = files.where((f) => f.size <= kMaxFileBytes).toList();
  if (sendable.isEmpty) return;

  // 聲報的 totalBytes 只算「真的會送」的檔案。之前把被略過的大檔也算進去,
  // 結果是:複製一個 600MB 影片加一個 20KB 字幕檔,只送字幕檔,
  // 卻聲稱總量 600MB → 對方以總量超限為由 413,連那 20KB 都同步不了。
  final total = sendable.fold(0, (a, f) => a + f.size);

  final transferId = _randomHex(8);

  // 對每台裝置各自「依序」送每個檔案(避免一次塞爆對方的頻寬),
  // 但不同裝置之間是平行的。
  final results = await Future.wait(targets.map((peer) async {
    for (var i = 0; i < sendable.length; i++) {
      final f = sendable[i];
      final meta = ClipMeta(
        kind: ClipKind.files,
        fromName: myName,
        fromDeviceId: myDeviceId,
        signature: snap.signature,
        seq: ++_seq,
        sentAtMs: DateTime.now().millisecondsSinceEpoch,
        mime: 'application/octet-stream',
        transferId: transferId,
        index: i,
        count: sendable.length,
        name: f.name,
        size: f.size,
        totalBytes: total,
      );
      final err = await sender.sendFile(peer, meta, f);
      if (err != null) return err;
      if (sendable.length > 1) {
        _log('   ↑ ${peer.name} ← ${f.name} (${i + 1}/${sendable.length})');
      }
    }
    return null;
  }));
  _reportSendResults(targets, results);
}

int _reportSendResults(List<Peer> targets, List<String?> results) {
  var ok = 0;
  for (var i = 0; i < targets.length; i++) {
    final peer = targets[i];
    final err = results[i];
    if (err == null) {
      ok++;
      peer.consecutiveFailures = 0;
    } else if (err == ContentSender.kLocalNetworkDenied) {
      peer.consecutiveFailures++;
      _log('   ✗ 送不到 ${peer.name}:被 macOS「本機網路」權限擋住');
      if (peer.consecutiveFailures == 1 || peer.consecutiveFailures % 20 == 0) {
        _log('     ├ 這不是網路問題:閘道器、自己的網卡、外網都連得到,');
        _log('     │  只有「區網裡的其他電腦」被核心的 NECP 政策丟棄。');
        _log('     ├ 請到 系統設定 → 隱私權與安全性 → 本機網路,把 ClipSync 打開。');
        _log('     └ 打開之後要重新啟動 ClipSync ——');
        _log('        權限狀態是程序啟動時快取的,不重啟不會生效。');
      }
    } else {
      peer.consecutiveFailures++;
      _log('   ✗ 送不到 ${peer.name}:$err');
      if (peer.consecutiveFailures == 3) {
        _log('     └ 心跳(UDP)通但內容(TCP)不通,可能是對方的防火牆擋了 TCP。'
            '在 ${peer.name} 上放行 TCP ${peer.contentPort} 試試。');
      }
    }
  }
  if (ok > 0) {
    _sentCount++;
    _log('   → 已同步到 $ok/${targets.length} 台裝置');
  }
  return ok;
}

// ───────────────────────────── 接收 ─────────────────────────────

/// 對方剛送內容給我們,顯然是活著的 —— 就算他的心跳廣播掉光了,
/// 也不該把他從裝置清單裡掃掉(掃掉之後他下一次推內容就會被當陌生 IP 擋下)。
void _markAlive(ClipMeta meta) {
  peers.byId(meta.fromDeviceId)?.lastSeen = DateTime.now();
}

/// 這則訊息是不是「同一台電腦上的另一個實例」發的?
///
/// deviceId = 機器碼-名字雜湊,比對機器碼前綴就知道。
///
/// 為什麼要特別處理:同機器的實例**共用同一個系統剪貼簿**,但各有各的
/// 收件匣。同機器訊息若照常寫入剪貼簿,會炸出一種很兇的迴圈:
/// 實例甲收到檔案寫進剪貼簿 → 實例乙看到「剪貼簿變了」而且檔案不在
/// **乙的**收件匣裡 → 當成使用者的新複製廣播回去 → 甲又收到、又寫入,
/// 檔名每一圈長一個 " (2)" → 收件匣以每秒數個檔案的速度增生(實測 418 個)。
/// 同機器的剪貼簿本來就是同一份,寫入毫無意義 —— 跳過寫入,迴圈就斷了。
bool _sameMachine(ClipMeta meta) {
  final mine = myDeviceId.split('-').first;
  final theirs = meta.fromDeviceId.split('-').first;
  return mine.isNotEmpty && mine == theirs;
}

Future<void> _onRemoteTextOrImage(ClipMeta meta, Uint8List bytes) async {
  _markAlive(meta);
  if (meta.fromDeviceId == myDeviceId) return; // 自己繞一圈回來的
  if (_isStale(meta)) {
    _log('⏭ 忽略來自 ${meta.fromName} 的舊訊息(比已套用的內容更早)');
    return;
  }
  if (watcher.paused) {
    _log('⏸ 已暫停,忽略來自 ${meta.fromName} 的內容');
    return;
  }
  if (_sameMachine(meta)) {
    // 同一台電腦的另一個實例:剪貼簿是同一份,對方寫過了就等於我寫過了。
    _lastApplied[meta.fromDeviceId] = (meta.sentAtMs, meta.seq);
    debugLog('同機器實例 ${meta.fromName} 的內容,跳過剪貼簿寫入');
    return;
  }
  if (watcher.isSameAsCurrent(meta.signature)) return; // 已經是同一份了

  final String? freshSig;
  if (meta.kind == ClipKind.text) {
    final text = utf8.decode(bytes, allowMalformed: true);
    freshSig = await watcher.applyRemote(() => clipboard.writeText(text));
    if (freshSig == null) {
      _log('⚠ 寫入剪貼簿失敗(來自 ${meta.fromName})');
      return;
    }
    _log('📋 ${meta.fromName} → 已寫入文字:${preview(text)}');
  } else {
    freshSig = await watcher.applyRemote(() => clipboard.writeImage(bytes));
    if (freshSig == null) {
      _log('⚠ 寫入圖片失敗(來自 ${meta.fromName})');
      return;
    }
    _log('🖼  ${meta.fromName} → 已寫入圖片:${humanBytes(bytes.length)},可以直接貼上');
  }
  _afterApply(meta, freshSig);
}

Future<void> _onRemoteFiles(ClipMeta meta, List<String> localPaths) async {
  _markAlive(meta);
  if (meta.fromDeviceId == myDeviceId) return;
  if (_isStale(meta)) {
    _log('⏭ 檔案已存到 $_inboxDir,但這是舊訊息,不放進剪貼簿');
    return;
  }
  if (watcher.paused) {
    _log('⏸ 已暫停,收到的檔案只存檔、不放進剪貼簿:$_inboxDir');
    return;
  }
  if (localPaths.isEmpty) return;
  if (_sameMachine(meta)) {
    // 檔案已經存進收件匣(自我測試要的就是這個),但剪貼簿不動 ——
    // 同機器共用剪貼簿,寫入只會觸發跨實例的檔名增生迴圈。
    _lastApplied[meta.fromDeviceId] = (meta.sentAtMs, meta.seq);
    _recvCount++;
    _log('📁 ${meta.fromName}(同一台電腦)→ 已收下 ${localPaths.length} 個檔案,'
        '存在 $_inboxDir(剪貼簿不變)');
    return;
  }

  // 檔案已經落地在 _inboxDir,現在把「本機的新路徑」放進剪貼簿。
  // 注意不能放對方給的路徑 —— 那個路徑在這台電腦上根本不存在。
  final freshSig =
      await watcher.applyRemote(() => clipboard.writeFiles(localPaths));
  final where = localPaths.first.substring(
      0, localPaths.first.lastIndexOf(Platform.pathSeparator));
  if (freshSig == null) {
    _log('⚠ 檔案已存到 $where,但放不進剪貼簿');
    return;
  }
  _log('📁 ${meta.fromName} → 已收下 ${localPaths.length} 個檔案,'
      '存在 $where,並已放進剪貼簿');
  _afterApply(meta, freshSig);
}

void _afterApply(ClipMeta meta, String freshSig) {
  _recvCount++;
  _lastApplied[meta.fromDeviceId] = (meta.sentAtMs, meta.seq);
  // 收到什麼就等於自己現在也擁有什麼。把 applyRemote 回報的**本機**新簽章
  // 記進「已廣播」,避免再送回去。直接用回傳值而不是 watcher.current ——
  // 佇列裡的下一個 apply 可能已經把 current 換掉了。
  // freshSig 為空字串 = 寫入成功但 reprobe 失敗 → 記 null(watcher 那邊
  // 已延長靜音期擋住回音)。
  _lastBroadcastSig = freshSig.isEmpty ? null : freshSig;
}

// ───────────────────────────── 指令列 ─────────────────────────────

Future<void> _onCommand(String line) async {
  final input = line.trim();
  if (input.isEmpty) return;

  if (!input.startsWith('/')) {
    await _sendTextManually(input);
    return;
  }

  final parts = input.split(RegExp(r'\s+'));
  switch (parts.first) {
    case '/peers':
    case '/p':
      if (peers.isEmpty) {
        _log('目前沒有發現任何裝置。');
      } else {
        _log('已發現 ${peers.length} 台裝置:');
        for (final p in peers.all) {
          stdout.writeln('    • $p');
        }
      }

    case '/pause':
      await ClipboardWatcher.setPaused(true);
      watcher.sessionPaused = true;
      _log('⏸ 已暫停同步(複製密碼時很好用)。用 /resume 恢復。');
      _log('  └ 這台電腦上所有 ClipSync(含背景執行的)都會一起暫停。');

    case '/resume':
      await ClipboardWatcher.setPaused(false);
      watcher.sessionPaused = false;
      _log('▶ 已恢復同步。');

    case '/send':
      final text = input.substring(parts.first.length).trim();
      if (text.isEmpty) {
        _log('用法:/send 要送出的文字');
      } else {
        await _sendTextManually(text);
      }

    case '/push':
      // 把「現在本機剪貼簿裡的東西」重新推一次(對方剛上線時很實用)
      final cur = watcher.current;
      if (cur == null) {
        _log('本機剪貼簿是空的,或裡面是不支援的格式。');
      } else {
        _log('重新推送目前剪貼簿內容(${cur.describe()})…');
        _lastBroadcastSig = null;
        await _onLocalClipboardChange(cur, force: true);
      }

    case '/inbox':
      _log(await _openInboxFolder());

    case '/ui':
      if (!webUi.available) {
        _log('這個實例沒有控制台(埠被同一台電腦上的另一個實例用走了)。');
      } else {
        _log('控制台:${webUi.url}(正在用瀏覽器打開…)');
        try {
          if (Platform.isMacOS) {
            await Process.run('open', [webUi.url]);
          } else if (Platform.isWindows) {
            await Process.run(
                'rundll32', ['url.dll,FileProtocolHandler', webUi.url]);
          } else {
            await Process.run('xdg-open', [webUi.url]);
          }
        } catch (_) {}
      }

    case '/status':
    case '/s':
      final up = DateTime.now().difference(_startedAt);
      _log('裝置:$myName  id=$myDeviceId  平台=${Platform.operatingSystem}');
      _log('剪貼簿後端:${clipboard.backendName}'
          '(圖片 ${clipboard.supportsImages ? "✓" : "✗"} / '
          '檔案 ${_filesEnabled && clipboard.supportsFiles ? "✓" : "✗"})');
      _log('內容埠:TCP ${server.port}   探索埠:UDP $kDiscoveryPort');
      _log('目前剪貼簿:${watcher.current?.describe() ?? "(空的)"}');
      _log('狀態:${watcher.paused ? "已暫停" : "同步中"}  '
          '已發現 ${peers.length} 台  送出 $_sentCount 次  收到 $_recvCount 次  '
          '執行 ${up.inMinutes} 分 ${up.inSeconds % 60} 秒');

    case '/help':
    case '/?':
      _printCommands();

    case '/quit':
    case '/q':
      await _shutdown();

    default:
      _log('不認識的指令:${parts.first}(打 /help 看清單)');
  }
}

/// 回傳送達的裝置數(控制台要用這個數字給使用者回饋)。
Future<int> _sendTextManually(String text) async {
  final sig = 'T:${shortHash(text)}:${text.length}';
  _log('📨 送出文字:${preview(text)}');
  // 送成功才記「已廣播」。先記再送的話,一次失敗(還沒發現任何裝置)就把
  // 這段文字永遠鎖住了 —— 之後使用者真的複製同一段文字,第 3 層回音防護
  // 會以為「送過了」而跳過,而且完全沒有訊息說明為什麼。
  final delivered =
      await _broadcastBytes(ClipKind.text, sig, utf8.encode(text), 'text/plain');
  if (delivered > 0) _lastBroadcastSig = sig;
  return delivered;
}

/// 在這台電腦上把收件匣資料夾打開(Finder / 檔案總管)。
Future<String> _openInboxFolder() async {
  try {
    final dir = Directory(_inboxDir);
    if (!await dir.exists()) {
      return '資料夾還不存在(收到第一個檔案時才會自動建立)';
    }
    if (Platform.isMacOS) {
      await Process.run('open', [_inboxDir]);
    } else if (Platform.isWindows) {
      // explorer 正常開啟也會回結束碼 1,不能拿它判斷成敗。
      await Process.run('explorer', [_inboxDir]);
    } else {
      await Process.run('xdg-open', [_inboxDir]);
    }
    return '已打開資料夾:$_inboxDir';
  } catch (e) {
    return '打不開資料夾($e),路徑是:$_inboxDir';
  }
}

/// 控制台要顯示的即時狀態。每次請求時現算,永遠是最新的。
Map<String, Object?> _statusForUi() {
  final now = DateTime.now();
  return {
    'name': myName,
    'id': myDeviceId,
    'platform': Platform.operatingSystem,
    'backend': clipboard.backendName,
    'paused': watcher.paused,
    'contentPort': server.port,
    'sent': _sentCount,
    'recv': _recvCount,
    'uptimeSec': now.difference(_startedAt).inSeconds,
    'inbox': _inboxDir,
    'clipboardNow': watcher.current?.describe() ?? '(空的)',
    'peers': [
      for (final p in peers.all)
        {
          'name': p.name,
          'platform': p.platform,
          'ip': p.ip,
          'altIps': p.altIps.toList(),
          'agoSec': now.difference(p.lastSeen).inSeconds,
          'compatible': p.isCompatible,
          'failures': p.consecutiveFailures,
        },
    ],
  };
}

String _randomHex(int bytes) => List.generate(
    bytes, (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

Future<void> _shutdown() async {
  _log('關閉中…');
  await discovery.sendGoodbye();
  await Future<void>.delayed(const Duration(milliseconds: 120));
  watcher.stop();
  discovery.stop();
  sender.close();
  await webUi.stop();
  await server.stop();
  exit(0);
}

// ───────────────────────────── 自我診斷 ─────────────────────────────

/// `dart run clipsync.dart --doctor`
///
/// 完全不碰網路,只測「這台電腦的剪貼簿讀寫到底能不能用」。
/// 網路問題和剪貼簿問題的症狀常常長得一樣(都是「沒反應」),
/// 先把後者排除掉,剩下的就好查很多。
Future<void> _runDoctor() async {
  stdout.writeln('\n  ClipSync 自我診斷');
  stdout.writeln('  ────────────────────────────────────────────');
  stdout.writeln('  平台        ${Platform.operatingSystem} '
      '${Platform.operatingSystemVersion}');
  stdout.writeln('  Dart        ${Platform.version.split(' ').first}');

  final SystemClipboard cb;
  try {
    cb = await SystemClipboard.detect();
  } on ClipboardUnavailable catch (e) {
    stdout.writeln('  ✗ 找不到可用的剪貼簿後端\n    $e');
    exitCode = 1;
    return;
  }
  stdout.writeln('  剪貼簿後端  ${cb.backendName}');
  stdout.writeln('  ────────────────────────────────────────────\n');

  var failures = 0;
  void check(bool ok, String label, [String? hint]) {
    stdout.writeln('  ${ok ? "✓" : "✗"} $label');
    if (!ok) {
      failures++;
      if (hint != null) stdout.writeln('      └ $hint');
    }
  }

  // 先記住使用者原本的剪貼簿,測完要還回去。
  final original = await cb.probe();
  stdout.writeln('  目前剪貼簿:${original?.describe() ?? "(空的,或是不支援的格式)"}\n');

  // ── 測試 1:文字來回 ──
  const sample = 'ClipSync 診斷測試 中文 🎉 abc';
  check(await cb.writeText(sample), '寫入文字', '剪貼簿寫入被系統擋住了?');
  final s1 = await cb.probe();
  check(s1 != null, 'probe() 讀得到東西',
      '這是 Windows 上最常見的失敗點 —— 用 CLIPSYNC_DEBUG=1 再跑一次看細節');
  check(s1?.kind == ClipKind.text, 'probe() 判定為文字(實際:${s1?.kind})');
  check(s1?.text == sample, '讀回來的文字與寫入的完全相同',
      s1?.text == null ? null : '讀到的是:${preview(s1!.text!)}');

  // ── 測試 2:偵測「內容變了」──
  final sigBefore = s1?.signature;
  await cb.writeText('$sample 第二次');
  final s2 = await cb.probe();
  check(s2 != null && s2.signature != sigBefore, 'signature 會隨內容改變',
      '如果 signature 不變,程式就永遠不知道你複製了新東西');

  // ── 測試 3:圖片來回 ──
  if (cb.supportsImages) {
    final png = tinyPng();
    final wroteImg = await cb.writeImage(png);
    check(wroteImg, '寫入圖片(${png.length} bytes 的測試 PNG)');
    if (wroteImg) {
      final s3 = await cb.probe();
      check(s3?.kind == ClipKind.image, 'probe() 判定為圖片(實際:${s3?.kind})');
      final back = await cb.readImageBytes();
      check(back != null && back.isNotEmpty, '讀得回圖片位元組');
      check(
        back != null && back.length > 8 && back[0] == 137 && back[1] == 80,
        '讀回來的是合法的 PNG',
        back == null ? null : '檔頭是 ${back.take(4).toList()}',
      );
    }
  } else {
    stdout.writeln('  - 這個後端不支援圖片,略過');
  }

  // ── 還原 ──
  if (original?.kind == ClipKind.text && original?.text != null) {
    await cb.writeText(original!.text!);
    stdout.writeln('\n  (已還原你原本的剪貼簿內容)');
  } else {
    await cb.writeText('');
    stdout.writeln('\n  (原本的剪貼簿內容不是文字,無法還原,已清空)');
  }

  stdout.writeln('  ────────────────────────────────────────────');
  if (failures == 0) {
    stdout.writeln('  ✓ 剪貼簿功能全部正常。');
    stdout.writeln('    如果同步還是不動,問題在網路 —— 看 README 的「收不到?排錯順序」。');
  } else {
    stdout.writeln('  ✗ 有 $failures 項失敗。');
    stdout.writeln('    請用 CLIPSYNC_DEBUG=1 dart run clipsync.dart --doctor 再跑一次,');
    stdout.writeln('    輸出裡會有系統回報的原始錯誤訊息。');
    exitCode = 1;
  }
  stdout.writeln('');
}

// ───────────────────────────── 輸出 ─────────────────────────────

/// 最近的活動,給網頁控制台看的(和終端機印的是同一份)。
/// 上限 300 行:控制台只需要「最近發生了什麼」,完整歷史在記錄檔裡。
final List<Map<String, String>> _recent = [];

void _log(String message) {
  final t = hhmmss();
  stdout.writeln('$t  $message');
  _recent.add({'t': t, 'm': message});
  if (_recent.length > 300) _recent.removeRange(0, _recent.length - 300);
}

Future<void> _printBanner(_Options opts) async {
  final ips = await localIPv4();
  stdout.writeln('');
  stdout.writeln('  ClipSync — 區網剪貼簿同步  (Step 3:文字 / 圖片 / 檔案)');
  stdout.writeln('  ────────────────────────────────────────────');
  stdout.writeln('  裝置名稱   $myName   (id: $myDeviceId)');
  stdout.writeln('  剪貼簿後端 ${clipboard.backendName}');
  stdout.writeln('  支援格式   文字 ✓   圖片 ${clipboard.supportsImages ? "✓" : "✗"}   '
      '檔案 ${_filesEnabled && clipboard.supportsFiles ? "✓" : "✗"}');
  stdout.writeln('  本機位址   ${ips.isEmpty ? "(找不到 IPv4 網卡)" : ips.join(", ")}');
  stdout.writeln('  探索       UDP $kDiscoveryPort 廣播,每 '
      '${kHeartbeatInterval.inSeconds} 秒一次');
  stdout.writeln('  內容       HTTP POST → TCP ${server.port}');
  if (webUi.available) {
    stdout.writeln('  控制台     ${webUi.url}   ← 用瀏覽器開這個,有圖形介面');
  }
  if (_filesEnabled) {
    stdout.writeln('  收檔位置   $_inboxDir');
    stdout.writeln('  接收上限   單檔 ${humanBytes(kMaxFileBytes)},'
        '單次 ${humanBytes(opts.maxTransferBytes)}');
  }
  if (_acceptFromAnyone) {
    stdout.writeln('  ⚠ --open:同網段任何人都能推內容進你的剪貼簿');
  }
  if (watcher.paused) {
    stdout.writeln('  ⏸ 以暫停狀態啟動,用 /resume 開始同步');
  }
  stdout.writeln('  ────────────────────────────────────────────');
  stdout.writeln('  複製文字、截圖、或檔案都會自動同步。打 /help 看指令。');
  stdout.writeln('');
}

void _printCommands() {
  stdout.writeln('''
  指令:
    /peers  /p      列出已發現的裝置
    /ui             用瀏覽器打開網頁控制台(圖形介面)
    /push           把目前剪貼簿的內容再推一次
    /send <文字>    直接送出一段文字(不碰本機剪貼簿)
    /inbox          顯示並開啟收到的檔案資料夾
    /pause          暫停同步(要複製密碼時用)
    /resume         恢復同步
    /status /s      看目前狀態與統計
    /quit   /q      離開
    直接打字 Enter  等同 /send
''');
}

void _printHelp() {
  stdout.writeln('''
ClipSync — 區網剪貼簿同步(Step 3:文字 / 圖片 / 檔案)

用法:
  dart run clipsync.dart [裝置名稱] [選項]

選項:
  --content-port <n>   內容用的 TCP port(預設 $kContentPort,被佔用會自動改用隨機 port)
  --poll <毫秒>        剪貼簿輪詢間隔(預設 ${kClipboardPollInterval.inMilliseconds})
  --inbox <路徑>       收到的檔案存哪裡(預設 ${defaultInboxDir()})
  --max-mb <n>         單次傳輸總量上限,MB(預設 ${kDefaultMaxTransferBytes ~/ (1024 * 1024)})
  --no-files           不收也不送檔案(只同步文字與圖片)
  --paused             啟動時先不同步
  --open               接受任何來源 IP 推內容(僅供除錯,不安全)
  --doctor             自我診斷:只測本機剪貼簿讀寫,完全不碰網路
  -h, --help           顯示這份說明

範例:
  dart run clipsync.dart Alice
  dart run clipsync.dart Bob --no-files            # 只要文字和圖片
  dart run clipsync.dart 測試機2 --content-port 53319   # 同一台電腦開第二個
''');
}

// ───────────────────────────── 參數 ─────────────────────────────

class _Options {
  String? name;
  int contentPort = kContentPort;
  Duration pollInterval = kClipboardPollInterval;
  int maxTransferBytes = kDefaultMaxTransferBytes;
  String? inboxDir;
  bool noFiles = false;
  bool startPaused = false;
  bool acceptFromAnyone = false;
  bool showHelp = false;
  bool doctor = false;

  static _Options parse(List<String> args) {
    final o = _Options();
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      // 缺值防護:「--inbox --paused」不該把 --paused 吃掉當路徑用。
      String? next() {
        if (i + 1 >= args.length) return null;
        if (args[i + 1].startsWith('-')) return null;
        return args[++i];
      }

      // 名字例外:裝置名是任意字串,「--name -小明-」也要照收。
      String? nextRaw() => i + 1 < args.length ? args[++i] : null;
      switch (a) {
        case '-h':
        case '--help':
          o.showHelp = true;
        case '--doctor':
          o.doctor = true;
        case '--name':
          // 啟動器一律用 --name 傳裝置名。位置參數仍然支援,但名字開頭
          // 是 '-' 時會被誤認成選項(想像使用者把名字取成 --open……),
          // 具名參數就沒有這個歧義。
          o.name = nextRaw();
        case '--name-file':
          // 名字放檔案裡,給 Windows 自動啟動用:名字若直接內嵌在 .cmd,
          // cmd 的 & | > 等中繼字元和編碼問題會一路炸到底。
          final path = nextRaw();
          if (path != null) {
            try {
              final content = File(path).readAsStringSync().trim();
              if (content.isNotEmpty) o.name = content;
            } catch (_) {
              stderr.writeln('讀不到名字檔:$path(改用預設名稱)');
            }
          }
        case '--content-port':
          o.contentPort = int.tryParse(next() ?? '') ?? kContentPort;
        case '--poll':
          final ms = int.tryParse(next() ?? '');
          if (ms != null && ms >= 100) o.pollInterval = Duration(milliseconds: ms);
        case '--inbox':
          o.inboxDir = next();
        case '--max-mb':
          final mb = int.tryParse(next() ?? '');
          if (mb != null && mb > 0) o.maxTransferBytes = mb * 1024 * 1024;
        case '--no-files':
          o.noFiles = true;
        case '--paused':
          o.startPaused = true;
        case '--open':
          o.acceptFromAnyone = true;
        default:
          if (a.startsWith('-')) {
            stderr.writeln('忽略不認識的選項:$a');
          } else {
            o.name ??= a;
          }
      }
    }
    return o;
  }
}
