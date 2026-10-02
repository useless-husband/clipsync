// 內容傳輸層:HTTP over TCP。
//
// 為什麼不用 UDP 傳內容?
//   - UDP 單一封包上限 64KB;一張截圖就破表了。
//   - UDP 不保證送達也不保證順序;剪貼簿同步「靜靜地失敗」是最糟的體驗。
//   - TCP/HTTP 免費給你:分段重傳、順序、還有「對方收到了嗎」的狀態碼。
//
// 分工:UDP 負責「找人」(小、頻繁、可丟),HTTP 負責「送貨」(大、要可靠)。
//
// v3 的格式:中繼資料放 x-clipsync-meta 標頭,body 是原始位元組。
// 檔案是**一個檔一個 POST**,大檔全程串流進磁碟,不會整包擠進記憶體。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'clip_content.dart';
import 'config.dart';
import 'message.dart';
import 'peer.dart';
import 'util.dart';

/// 收到一份完整內容時的回呼。
typedef OnTextOrImage = Future<void> Function(ClipMeta meta, Uint8List bytes);
typedef OnFilesComplete = Future<void> Function(
    ClipMeta meta, List<String> localPaths);

class ContentServer {
  ContentServer({
    required this.onTextOrImage,
    required this.onFilesComplete,
    required this.isAllowed,
    required this.inboxDir,
    required this.maxTransferBytes,
    required this.acceptFiles,
  });

  final OnTextOrImage onTextOrImage;
  final OnFilesComplete onFilesComplete;
  final bool Function(String ip) isAllowed;
  final String inboxDir;
  final int maxTransferBytes;
  final bool acceptFiles;

  void Function(String message)? onLog;

  HttpServer? _server;
  int _port = 0;
  int get port => _port;

  final Map<String, _Incoming> _transfers = {};
  Timer? _sweepTimer;

  Future<void> start({int preferredPort = kContentPort}) async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, preferredPort);
    } on SocketException {
      // port 被佔用(最常見:同一台電腦開第二個 ClipSync 自我測試)。
      // 改用系統隨機分配的 port,再透過心跳告訴對方 —— 所以心跳裡才要有 contentPort。
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      onLog?.call('port $preferredPort 已被佔用,改用 ${_server!.port}');
    }
    _port = _server!.port;
    _server!.listen(_handle,
        onError: (Object e) => onLog?.call('HTTP 伺服器錯誤:$e'));

    // 沒收齊的多檔傳輸不能一直佔著,定期清掉。
    // ⚠ 判斷基準是「最後一次有動靜」而不是「開始至今」:
    // 傳 3 個大檔可能要好幾分鐘,只看開始時間的話,傳到一半整個傳輸就被
    // 掃掉了 —— 後面的檔案到達時 putIfAbsent 建出一個殘缺的新傳輸,
    // 完成條件永遠不成立,收端剪貼簿不更新,送端卻每個檔都拿到 200 以為成功。
    _sweepTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      final now = DateTime.now();
      _transfers.removeWhere((id, t) {
        final dead = now.difference(t.lastActivity) > kTransferTimeout;
        if (dead) {
          onLog?.call('⚠ 傳輸逾時,丟棄未完成的 ${t.received.length}/${t.count} 個檔案');
        }
        return dead;
      });
    });
  }

  Future<void> stop() async {
    _sweepTimer?.cancel();
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest req) async {
    final ip = req.connectionInfo?.remoteAddress.address ?? '?';

    // 極簡健康檢查,排錯時可以直接用瀏覽器打 http://對方IP:53318/ping
    if (req.method == 'GET' && req.uri.path == '/ping') {
      return _reply(req, HttpStatus.ok, {'app': kApp, 'v': kProtocolVersion});
    }

    if (req.method != 'POST' || req.uri.path != '/clip') {
      return _reply(req, HttpStatus.notFound, {'error': 'not found'}, drain: true);
    }

    // 目前的「安全」只有這一層:只收已經在裝置清單裡的 IP。
    // 這擋得住手滑的鄰居,擋不住有心人 —— Step 4 的配對 + 加密才是正解。
    if (!isAllowed(ip)) {
      onLog?.call('⚠ 拒絕來自 $ip 的內容(不在已知裝置清單中)');
      return _reply(req, HttpStatus.forbidden, {'error': 'unknown peer'}, drain: true);
    }

    // 不用 headers.value():同名標頭出現兩次時它會直接 throw,而這裡的
    // 標頭是遠端給的 —— 惡意的重複標頭不該讓請求懸在那裡沒人回。
    final metaValues = req.headers[kMetaHeader];
    final meta = ClipMeta.decodeHeader(
        (metaValues == null || metaValues.isEmpty) ? null : metaValues.first);
    if (meta == null) {
      return _reply(req, HttpStatus.badRequest, {'error': 'bad meta'}, drain: true);
    }

    try {
      switch (meta.kind) {
        case ClipKind.text:
        case ClipKind.image:
          final cap =
              meta.kind == ClipKind.text ? kMaxTextBytes : kMaxImageBytes;
          final bytes = await _readCapped(req, cap);
          if (bytes == null) {
            onLog?.call('⚠ 來自 ${meta.fromName} 的內容超過上限,已拒收');
            return _reply(req, HttpStatus.requestEntityTooLarge,
                {'error': 'too large'}, drain: true);
          }
          await onTextOrImage(meta, bytes);
          return _reply(req, HttpStatus.ok, {'ok': true});

        case ClipKind.files:
          if (!acceptFiles) {
            return _reply(req, HttpStatus.forbidden, {'error': 'files disabled'},
                drain: true);
          }
          return _handleFile(req, meta);
      }
    } catch (e) {
      onLog?.call('處理內容時出錯:$e');
      try {
        return _reply(req, HttpStatus.internalServerError, {'error': '$e'},
            drain: true);
      } catch (_) {}
    }
  }

  Future<void> _handleFile(HttpRequest req, ClipMeta meta) async {
    final tid = meta.transferId;
    // count/index 都是遠端給的,照單全收的話:負的 index、天文數字的 count、
    // 或同一個 transferId 內每則訊息講的 count 不一樣,都會讓組裝邏輯出軌。
    if (tid == null || meta.count <= 0 || meta.count > 10000) {
      return _reply(req, HttpStatus.badRequest, {'error': 'bad transfer'},
          drain: true);
    }
    if (meta.totalBytes > maxTransferBytes) {
      onLog?.call('⚠ ${meta.fromName} 想傳 ${humanBytes(meta.totalBytes)},'
          '超過上限 ${humanBytes(maxTransferBytes)},已拒收');
      return _reply(req, HttpStatus.requestEntityTooLarge, {'error': 'too large'},
          drain: true);
    }

    final t = _transfers.putIfAbsent(
        tid, () => _Incoming(tid, meta.count, meta.fromName));
    t.lastActivity = DateTime.now();
    if (meta.count != t.count || meta.index < 0 || meta.index >= t.count) {
      return _reply(req, HttpStatus.badRequest, {'error': 'bad index'},
          drain: true);
    }

    final dir = Directory(inboxDir);
    if (!await dir.exists()) await dir.create(recursive: true);

    // ⚠ 檔名是遠端給的,一定要消毒。不然對方送一個叫 "../../.ssh/authorized_keys"
    // 的檔案就能寫到任意位置 —— 這是經典的 path traversal。
    final safe = _safeName(meta.name ?? 'clipsync_file');
    // _uniquePath 會用 create(exclusive) **原子性地佔住**最終檔名。
    // 光檢查「檔案存在嗎」是不夠的:兩個同名傳輸同時進來時,兩邊都會看到
    // 「不存在」,然後寫進同一個 .part —— 兩條串流交錯寫進同一個檔案,
    // 使用者拿到的是一個看起來成功、實際上內容爛掉的檔案。
    final String target;
    try {
      target = await _uniquePath(dir.path, safe);
    } catch (e) {
      return _reply(req, HttpStatus.internalServerError, {'error': '$e'},
          drain: true);
    }
    // .part 檔名也帶上 transferId 與 index,保證每個請求寫自己的檔。
    final file = File('$target.${_token(tid)}-${meta.index}.part');

    Future<void> cleanup() async {
      for (final f in [file, File(target)]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }

    final sink = file.openWrite();
    var written = 0;
    try {
      await for (final chunk in req) {
        written += chunk.length;
        if (written > kMaxFileBytes) {
          throw const FileSystemException('單一檔案超過上限');
        }
        // 送端聲稱的 totalBytes 只是聲稱 —— 實際收了多少要自己算,
        // 不然謊報 totalBytes=1KB 就能繞過總量上限。
        if (t.bytes + written > maxTransferBytes) {
          throw const FileSystemException('傳輸總量超過上限');
        }
        sink.add(chunk);
        t.lastActivity = DateTime.now();
      }
      await sink.flush();
      await sink.close();
      await file.rename(target);
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      await cleanup();
      onLog?.call('⚠ 接收 $safe 失敗:$e');
      return _reply(req, HttpStatus.requestEntityTooLarge, {'error': '$e'},
          drain: true);
    }

    t.received[meta.index] = target;
    t.bytes += written;
    t.lastActivity = DateTime.now();
    onLog?.call('  ↓ ${meta.fromName} → $safe (${humanBytes(written)}) '
        '[${t.received.length}/${t.count}]');

    if (t.received.length >= t.count) {
      _transfers.remove(tid);
      final ordered = [
        for (var i = 0; i < t.count; i++)
          if (t.received[i] != null) t.received[i]!
      ];
      await onFilesComplete(meta, ordered);
    }
    return _reply(req, HttpStatus.ok, {'ok': true});
  }

  /// 讀 body,超過上限就回 null(而不是把記憶體吃爆)。
  Future<Uint8List?> _readCapped(HttpRequest req, int cap) async {
    final out = BytesBuilder(copy: false);
    await for (final chunk in req) {
      out.add(chunk);
      if (out.length > cap) return null;
    }
    return out.takeBytes();
  }

  /// [drain] 一定要在「還沒把 body 讀完就要回錯誤」的路徑上設 true。
  ///
  /// 為什麼:HTTP 是全雙工的。對方可能還在拚命送 5MB 的圖片,我們卻直接回
  /// 403 然後關閉連線 —— TCP 這邊會變成「對方還在寫、我方已經關」,
  /// 送出端看到的就是 `Connection reset by peer`,完全看不出真正的原因。
  /// 先把 body 收完再回應,錯誤訊息才會誠實。
  Future<void> _reply(HttpRequest req, int status, Map<String, dynamic> body,
      {bool drain = false}) async {
    if (drain) {
      try {
        await req.drain<void>();
      } catch (_) {}
    }
    try {
      req.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await req.response.close();
    } catch (_) {}
  }
}

class _Incoming {
  _Incoming(this.transferId, this.count, this.fromName)
      : lastActivity = DateTime.now();
  final String transferId;
  final int count;
  final String fromName;
  DateTime lastActivity;
  final Map<int, String> received = {};
  int bytes = 0;
}

/// transferId 是遠端給的字串,要放進檔名前先過濾成安全字元。
String _token(String raw) {
  final buf = StringBuffer();
  for (final c in raw.codeUnits) {
    final ch = String.fromCharCode(c);
    if (RegExp(r'[a-zA-Z0-9]').hasMatch(ch)) buf.write(ch);
    if (buf.length >= 16) break;
  }
  return buf.isEmpty ? 'x' : buf.toString();
}

/// 把遠端給的檔名變成安全的檔名。
///
/// 除了路徑分隔符與 ".."(path traversal),還要處理 Windows 的規矩:
/// `< > : " | ? *` 是非法字元、CON/NUL/COM1… 是保留名、結尾的點和空白
/// 會被系統默默吃掉 —— 少處理任何一樣,收到那個檔名的 Windows 機器就會
/// 在寫入時炸掉,整個多檔傳輸跟著失敗。
String _safeName(String raw) {
  var name = raw.replaceAll('\\', '/').split('/').last.trim();
  name = name.replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '');
  while (name.startsWith('.')) {
    name = name.substring(1);
  }
  while (name.endsWith('.') || name.endsWith(' ')) {
    name = name.substring(0, name.length - 1);
  }
  if (name.isEmpty) name = 'clipsync_file';
  final stemUpper = name.split('.').first.toUpperCase();
  const reserved = {
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };
  if (reserved.contains(stemUpper)) name = '_$name';
  if (name.length > 120) name = name.substring(name.length - 120);
  return name;
}

/// 同名時加 (2)、(3)…,並用 create(exclusive) **原子性地佔住**選中的名字,
/// 讓並行的傳輸不可能拿到同一個路徑。佔位的空檔案最後會被 rename 覆蓋。
Future<String> _uniquePath(String dir, String name) async {
  final sep = Platform.pathSeparator;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';

  for (var i = 1; i < 1000; i++) {
    final candidate = i == 1 ? '$dir$sep$name' : '$dir$sep$stem ($i)$ext';
    try {
      await File(candidate).create(exclusive: true);
      return candidate;
    } on FileSystemException {
      continue; // 已存在(或剛被別的傳輸佔走)→ 試下一個編號
    }
  }
  throw const FileSystemException('找不到可用的檔名');
}

// ═══════════════════════════════ 送出端 ═══════════════════════════════

class ContentSender {
  final HttpClient _client = HttpClient()
    ..connectionTimeout = kSendTimeout
    ..idleTimeout = const Duration(seconds: 20);

  /// 主動確認對方還在不在(TCP)。
  ///
  /// 為什麼需要這個:心跳走 UDP 廣播,而廣播在 Wi-Fi 上掉得非常兇 ——
  /// 實測某台機器 75 秒只有 9 個廣播封包穿過來,但同一時間 TCP 連線
  /// 20 次全部成功。只靠廣播判斷生死,會把明明活著的裝置誤判成離線。
  Future<bool> ping(Peer peer) async {
    HttpClientRequest? req;
    try {
      req = await _client
          .getUrl(Uri.parse('${peer.endpoint}/ping'))
          .timeout(const Duration(seconds: 3));
      final res = await req.close().timeout(const Duration(seconds: 3));
      await res.drain<void>();
      return res.statusCode == HttpStatus.ok;
    } catch (_) {
      req?.abort();
      return false;
    }
  }

  /// 送文字或圖片。回傳 null 表示成功,否則回傳錯誤描述。
  Future<String?> sendBytes(Peer peer, ClipMeta meta, List<int> body) async {
    HttpClientRequest? req;
    try {
      req = await _client
          .postUrl(Uri.parse('${peer.endpoint}/clip'))
          .timeout(kSendTimeout);
      req.headers.set(kMetaHeader, meta.encodeHeader());
      req.headers.contentType = ContentType.binary;
      req.headers.contentLength = body.length;
      req.add(body);
      final res = await req.close().timeout(kSendTimeout);
      await res.drain<void>();
      return res.statusCode == HttpStatus.ok ? null : _statusError(res.statusCode);
    } on TimeoutException {
      // abort 不能省:逾時的連線不收掉的話會一直佔著,之後的請求還可能
      // 撿到這條半死的連線繼續失敗。
      req?.abort();
      return '逾時';
    } catch (e) {
      req?.abort();
      return _friendly(e);
    }
  }

  /// 送一個檔案。從磁碟串流出去,不會把整個檔案讀進記憶體。
  Future<String?> sendFile(Peer peer, ClipMeta meta, ClipFileRef file) async {
    HttpClientRequest? req;
    try {
      final f = File(file.path);
      if (!await f.exists()) return '檔案不存在';

      req = await _client
          .postUrl(Uri.parse('${peer.endpoint}/clip'))
          .timeout(kSendTimeout);
      req.headers.set(kMetaHeader, meta.encodeHeader());
      req.headers.contentType = ContentType.binary;
      req.headers.contentLength = file.size;
      // addStream 也要有時間上限:對方收到一半當掉的話,這裡會永遠等下去,
      // 而 _broadcastFiles 是照裝置依序送的 —— 一台卡住,整條佇列跟著卡。
      await req.addStream(f.openRead()).timeout(kFileSendTimeout);
      final res = await req.close().timeout(kFileSendTimeout);
      await res.drain<void>();
      return res.statusCode == HttpStatus.ok ? null : _statusError(res.statusCode);
    } on TimeoutException {
      req?.abort();
      return '逾時';
    } catch (e) {
      req?.abort();
      return _friendly(e);
    }
  }

  String _statusError(int code) => switch (code) {
        HttpStatus.forbidden => '對方拒收(可能還不認得我,或關閉了檔案接收)',
        HttpStatus.requestEntityTooLarge => '對方認為內容太大',
        _ => 'HTTP $code',
      };

  /// errno 65 = EHOSTUNREACH。對區網裡的**其他裝置**出現這個錯誤,在
  /// macOS 上幾乎都不是網路問題,而是「本機網路」隱私權限沒開:核心的
  /// NECP 政策引擎在封包送出去之前就把 SYN 丟掉,回報成 EHOSTUNREACH。
  /// 特徵是閘道器、自己的網卡、外網全部正常,只有區網對等裝置不通。
  static const String kLocalNetworkDenied = '__LOCAL_NETWORK_DENIED__';

  String _friendly(Object e) {
    if (e is SocketException) {
      if (Platform.isMacOS && e.osError?.errorCode == 65) {
        return kLocalNetworkDenied;
      }
      return '連不上(${e.osError?.message ?? '連線被拒'})';
    }
    return '$e';
  }

  void close() => _client.close(force: true);
}
