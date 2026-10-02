// 網頁控制台 —— ClipSync 的圖形介面。
//
// 為什麼是「網頁」而不是原生視窗:
//   1. 這個專題的約束是純 Dart、零外部套件。原生 GUI 要嘛引入 Flutter
//      (Windows 上編譯還得先裝 Visual Studio),要嘛每個平台各寫一套。
//   2. 程式本來就有 HTTP 伺服器(內容同步用),多開一個埠、回一頁 HTML,
//      成本幾乎是零。
//   3. 瀏覽器把「跨平台一致的畫面」這件事做掉了 —— 同一份 HTML,
//      Mac 和 Windows 上長得完全一樣。這正是使用者要的。
//
// 安全設計(很重要,報告可以寫一整段):
//   - 只綁 127.0.0.1:區網上其他電腦連不進來。控制台能暫停同步、能送文字,
//     這些權力只該屬於坐在這台電腦前面的人。
//   - 檢查 Host 標頭:擋「DNS rebinding」—— 惡意網站把自己的網域名稱解析到
//     127.0.0.1,騙瀏覽器帶著它的網域來打我們的 API。比對 Host 就擋掉了。
//   - 所有會改狀態的 POST 都要求自訂標頭 x-clipsync-ui:別的網頁要送這種
//     標頭,瀏覽器會先發 CORS preflight 問我們可不可以 —— 我們從不回應
//     preflight,所以跨站請求根本發不出來(CSRF 防護)。
//   - 讀取類的 GET 沒有 CORS 標頭:別的網站就算發得出請求,也讀不到回應
//     (瀏覽器的同源政策)。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'config.dart';

class WebUi {
  WebUi({
    required this.status,
    required this.events,
    required this.setPaused,
    required this.sendText,
    required this.pushClipboard,
    required this.openInbox,
  });

  /// 目前狀態(裝置、統計、剪貼簿內容摘要…),每次請求時現算。
  final Map<String, Object?> Function() status;

  /// 最近的活動記錄(和印在終端機的同一份)。
  final List<Map<String, String>> Function() events;

  final Future<void> Function(bool paused) setPaused;

  /// 回傳送達的裝置數。
  final Future<int> Function(String text) sendText;

  /// 回傳給使用者看的結果訊息。
  final Future<String> Function() pushClipboard;
  final Future<String> Function() openInbox;

  void Function(String msg)? onLog;

  HttpServer? _server;
  bool get available => _server != null;
  int get port => _server?.port ?? kUiPort;
  String get url => 'http://127.0.0.1:$port';

  Future<void> start() async {
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, kUiPort);
    } on SocketException {
      // 同一台電腦開了第二個實例:控制台由先開的那個提供,這個實例安靜跳過。
      onLog?.call('(控制台埠 $kUiPort 已被另一個實例使用,這個實例不提供網頁控制台)');
      return;
    }
    _server!.listen(_handle, onError: (Object _) {});
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// Host 標頭必須是我們自己。擋 DNS rebinding(見檔頭說明)。
  bool _hostOk(HttpRequest req) {
    final host = req.headers.value('host') ?? '';
    return host == '127.0.0.1:$port' || host == 'localhost:$port';
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers.set('cache-control', 'no-store');
    try {
      if (!_hostOk(req)) {
        await _deny(req, HttpStatus.forbidden);
        return;
      }

      if (req.method == 'GET') {
        switch (req.uri.path) {
          case '/':
          case '/index.html':
            res.headers.contentType = ContentType('text', 'html', charset: 'utf-8');
            res.write(_pageHtml);
            await res.close();
          case '/api/status':
            await _json(res, {...status(), 'events': events()});
          default:
            await _deny(req, HttpStatus.notFound);
        }
        return;
      }

      if (req.method == 'POST') {
        // CSRF 防護:跨站請求帶不了自訂標頭(見檔頭說明)。
        if (req.headers.value('x-clipsync-ui') != '1') {
          await _deny(req, HttpStatus.forbidden);
          return;
        }
        switch (req.uri.path) {
          case '/api/pause':
            await _drain(req);
            await setPaused(true);
            await _json(res, {'ok': true});
          case '/api/resume':
            await _drain(req);
            await setPaused(false);
            await _json(res, {'ok': true});
          case '/api/push':
            await _drain(req);
            await _json(res, {'ok': true, 'msg': await pushClipboard()});
          case '/api/open-inbox':
            await _drain(req);
            await _json(res, {'ok': true, 'msg': await openInbox()});
          case '/api/send':
            final body = await _readBody(req);
            if (body == null) {
              await _deny(req, HttpStatus.requestEntityTooLarge);
              return;
            }
            var text = '';
            try {
              final m = jsonDecode(body);
              if (m is Map && m['text'] is String) text = m['text'] as String;
            } catch (_) {}
            if (text.trim().isEmpty) {
              await _json(res, {'ok': false, 'msg': '沒有輸入文字'});
              return;
            }
            final n = await sendText(text);
            await _json(res, {'ok': true, 'delivered': n});
          default:
            await _deny(req, HttpStatus.notFound);
        }
        return;
      }

      await _deny(req, HttpStatus.methodNotAllowed);
    } catch (_) {
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _json(HttpResponse res, Map<String, Object?> data) async {
    res.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
    res.write(jsonEncode(data));
    await res.close();
  }

  /// 拒絕之前先把 request body 收乾。不收乾就回應,對方會看到
  /// connection reset 而不是我們精心準備的狀態碼(transport.dart 的老教訓)。
  Future<void> _deny(HttpRequest req, int code) async {
    await _drain(req);
    req.response.statusCode = code;
    await req.response.close();
  }

  Future<void> _drain(HttpRequest req) async {
    try {
      await req.drain<void>();
    } catch (_) {}
  }

  /// 讀 POST body,超過上限回 null(送文字最多 kMaxTextBytes,再多是異常)。
  Future<String?> _readBody(HttpRequest req) async {
    final buf = BytesBuilder(copy: false);
    await for (final chunk in req) {
      buf.add(chunk);
      if (buf.length > kMaxTextBytes + 65536) return null;
    }
    return utf8.decode(buf.takeBytes(), allowMalformed: true);
  }
}

// ─────────────────────────── 頁面本體 ───────────────────────────
// 整頁內嵌在程式裡(而不是讀外部檔案):編譯成單一執行檔後不會有
// 「HTML 檔忘了一起複製」的問題。零框架、零外部資源,斷網也能開。

const String _pageHtml = r'''<!doctype html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ClipSync 控制台</title>
<style>
  :root {
    --bg: #f4f5f7; --card: #ffffff; --ink: #1c1e21; --sub: #65707c;
    --line: #e3e6ea; --accent: #2563eb; --accent-ink: #ffffff;
    --ok: #16a34a; --warn: #d97706; --bad: #dc2626; --chip: #eef1f5;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #14161a; --card: #1e2126; --ink: #e8eaed; --sub: #98a1ab;
      --line: #2c3037; --accent: #3b82f6; --accent-ink: #ffffff; --chip: #262a31;
    }
  }
  * { box-sizing: border-box; margin: 0; }
  body {
    background: var(--bg); color: var(--ink);
    font: 15px/1.6 system-ui, -apple-system, "Segoe UI", "Microsoft JhengHei", sans-serif;
    padding: 0 16px 40px;
  }
  header {
    max-width: 980px; margin: 0 auto; padding: 18px 4px 10px;
    display: flex; align-items: center; justify-content: space-between; gap: 12px;
  }
  .brand { font-size: 22px; font-weight: 700; letter-spacing: .5px; }
  .me { display: flex; align-items: center; gap: 8px; color: var(--sub); font-size: 14px; }
  .dot { width: 10px; height: 10px; border-radius: 50%; background: #9ca3af; }
  .dot.on { background: var(--ok); box-shadow: 0 0 0 4px color-mix(in srgb, var(--ok) 20%, transparent); }
  .dot.paused { background: var(--warn); }
  main { max-width: 980px; margin: 0 auto; display: grid; gap: 14px; }
  .grid { display: grid; gap: 14px; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); }
  .card {
    background: var(--card); border: 1px solid var(--line); border-radius: 14px;
    padding: 16px 18px; box-shadow: 0 1px 3px rgba(0,0,0,.05);
  }
  .card h2 { font-size: 13px; font-weight: 600; color: var(--sub); text-transform: none; margin-bottom: 10px; }
  .pill {
    display: inline-block; min-width: 22px; text-align: center; background: var(--chip);
    border-radius: 999px; font-size: 12px; padding: 1px 8px; color: var(--ink);
  }
  .big { font-size: 26px; font-weight: 700; margin-bottom: 10px; }
  .big.paused { color: var(--warn); }
  .btn {
    appearance: none; border: 1px solid var(--line); background: var(--chip); color: var(--ink);
    border-radius: 10px; padding: 9px 14px; font-size: 14px; cursor: pointer;
    transition: transform .05s ease;
  }
  .btn:active { transform: scale(.97); }
  .btn.primary { background: var(--accent); border-color: var(--accent); color: var(--accent-ink); }
  .btn.warn { background: var(--warn); border-color: var(--warn); color: #fff; }
  .btn[disabled] { opacity: .5; cursor: default; }
  .hint { color: var(--sub); font-size: 12.5px; margin-top: 10px; }
  .stats { display: flex; gap: 16px; margin-top: 12px; color: var(--sub); font-size: 13px; flex-wrap: wrap; }
  .stats b { color: var(--ink); }
  ul.peers { list-style: none; display: grid; gap: 8px; }
  ul.peers li {
    display: flex; align-items: center; gap: 10px; padding: 9px 12px;
    background: var(--chip); border-radius: 10px;
  }
  .picon { font-size: 20px; }
  .pname { font-weight: 600; }
  .pmeta { color: var(--sub); font-size: 12.5px; }
  .pwarn { color: var(--bad); font-size: 12.5px; }
  .empty { color: var(--sub); font-size: 13.5px; padding: 8px 2px; }
  textarea {
    width: 100%; min-height: 74px; resize: vertical; border: 1px solid var(--line);
    border-radius: 10px; background: var(--bg); color: var(--ink);
    font: inherit; padding: 10px 12px; margin-bottom: 10px;
  }
  textarea:focus { outline: 2px solid var(--accent); outline-offset: -1px; }
  .row { display: flex; gap: 8px; flex-wrap: wrap; }
  .mono {
    font-family: ui-monospace, Menlo, Consolas, monospace; font-size: 12.5px;
    color: var(--sub); word-break: break-all; margin-bottom: 10px;
  }
  .log {
    font-family: ui-monospace, Menlo, Consolas, monospace; font-size: 12.5px;
    line-height: 1.7; white-space: pre-wrap; word-break: break-word;
    max-height: 320px; overflow-y: auto; color: var(--ink);
    background: var(--bg); border-radius: 10px; padding: 12px 14px;
  }
  .offline {
    background: color-mix(in srgb, var(--bad) 12%, var(--card));
    border: 1px solid var(--bad); border-radius: 12px; padding: 12px 16px; font-size: 14px;
  }
  .hidden { display: none; }
  footer { max-width: 980px; margin: 22px auto 0; color: var(--sub); font-size: 12px; text-align: center; }
  .toast {
    position: fixed; left: 50%; bottom: 26px; transform: translateX(-50%);
    background: var(--ink); color: var(--card); padding: 10px 18px; border-radius: 999px;
    font-size: 14px; box-shadow: 0 4px 16px rgba(0,0,0,.25); transition: opacity .25s;
  }
</style>
</head>
<body>
<header>
  <div class="brand">📋 ClipSync</div>
  <div class="me"><span id="dot" class="dot"></span><span id="myname">連線中…</span></div>
</header>
<main>
  <div id="offline" class="offline hidden">
    ⚠ 連不上 ClipSync —— 程式可能已經關閉。請點兩下 mac-手動啟動.command(Mac)
    或 win-手動啟動.bat(Windows)重新開啟,這頁會自動恢復。
  </div>

  <section class="grid">
    <div class="card">
      <h2>同步狀態</h2>
      <div class="big" id="stateText">—</div>
      <button id="pauseBtn" class="btn primary">…</button>
      <p class="hint">要複製密碼之前先按暫停,才不會同步到另一台電腦。</p>
      <div class="stats">
        <span>📤 送出 <b id="sent">0</b> 次</span>
        <span>📥 收到 <b id="recv">0</b> 次</span>
        <span>⏱ 已執行 <b id="uptime">—</b></span>
      </div>
    </div>

    <div class="card">
      <h2>已連上的電腦 <span id="peerCount" class="pill">0</span></h2>
      <ul id="peers" class="peers"></ul>
      <div id="noPeers" class="empty">
        還沒發現其他電腦。<br>
        確認另一台也開著 ClipSync,而且連的是同一台路由器。
      </div>
    </div>

    <div class="card">
      <h2>直接送一段文字</h2>
      <textarea id="sendText" placeholder="在這裡打字,按「送出」,另一台電腦就能直接貼上。&#10;(不會動到這台電腦的剪貼簿)"></textarea>
      <div class="row">
        <button id="sendBtn" class="btn primary">📨 送出</button>
        <button id="pushBtn" class="btn" title="對方剛開機沒收到?按這個把目前剪貼簿的內容再推一次">🔁 把目前剪貼簿再推一次</button>
      </div>
    </div>

    <div class="card">
      <h2>收到的檔案放在</h2>
      <div class="mono" id="inbox">—</div>
      <button id="inboxBtn" class="btn">📂 打開資料夾</button>
      <p class="hint" id="clipNow"></p>
    </div>
  </section>

  <section class="card">
    <h2>活動記錄</h2>
    <pre id="log" class="log">(還沒有活動)</pre>
  </section>
</main>
<footer id="foot">ClipSync — 純 Dart 專題製作</footer>
<div id="toast" class="toast hidden"></div>

<script>
const $ = id => document.getElementById(id);
let paused = false, toastTimer = null;

function toast(msg) {
  const t = $('toast');
  t.textContent = msg;
  t.classList.remove('hidden');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.add('hidden'), 2600);
}

function esc(s) {
  return String(s).replace(/[&<>"']/g, c =>
    ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

function fmtUptime(sec) {
  if (sec < 3600) return Math.floor(sec / 60) + ' 分 ' + (sec % 60) + ' 秒';
  return Math.floor(sec / 3600) + ' 小時 ' + Math.floor(sec % 3600 / 60) + ' 分';
}

function platIcon(p) {
  return {windows: '🪟', macos: '🍎', linux: '🐧'}[p] || '💻';
}

async function post(path, body) {
  const r = await fetch(path, {
    method: 'POST',
    headers: {'x-clipsync-ui': '1', 'content-type': 'application/json'},
    body: body ? JSON.stringify(body) : '{}',
  });
  if (!r.ok) throw new Error('HTTP ' + r.status);
  return r.json();
}

function render(s) {
  $('myname').textContent = s.name + '(這台電腦)';
  paused = s.paused;
  $('dot').className = 'dot ' + (paused ? 'paused' : 'on');
  const st = $('stateText');
  st.textContent = paused ? '⏸ 已暫停' : '✓ 同步中';
  st.className = 'big' + (paused ? ' paused' : '');
  const b = $('pauseBtn');
  b.textContent = paused ? '▶ 恢復同步' : '⏸ 暫停同步';
  b.className = 'btn ' + (paused ? 'primary' : 'warn');
  $('sent').textContent = s.sent;
  $('recv').textContent = s.recv;
  $('uptime').textContent = fmtUptime(s.uptimeSec);
  $('inbox').textContent = s.inbox;
  $('clipNow').textContent = '目前剪貼簿:' + s.clipboardNow;
  $('foot').textContent = 'ClipSync — 純 Dart 專題製作 · ' + s.name +
      ' · ' + s.backend + ' · 內容埠 ' + s.contentPort;

  $('peerCount').textContent = s.peers.length;
  $('noPeers').classList.toggle('hidden', s.peers.length > 0);
  $('peers').innerHTML = s.peers.map(p => {
    let warn = '';
    if (!p.compatible) warn = '⚠ 版本不合,請更新對方的 ClipSync';
    else if (p.failures > 0) warn = '⚠ 送不進去(連續 ' + p.failures + ' 次失敗)';
    return '<li><span class="picon">' + platIcon(p.platform) + '</span>' +
      '<span><span class="pname">' + esc(p.name) + '</span><br>' +
      '<span class="pmeta">' + esc(p.ip) + ' · ' + p.agoSec + ' 秒前有心跳' +
      (p.altIps.length ? ' · 另有 ' + esc(p.altIps.join('、')) : '') + '</span>' +
      (warn ? '<br><span class="pwarn">' + warn + '</span>' : '') +
      '</span></li>';
  }).join('');

  const log = $('log');
  const nearBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 40;
  const text = s.events.map(e => e.t + '  ' + e.m).join('\n');
  if (log.textContent !== text) {
    log.textContent = text || '(還沒有活動)';
    if (nearBottom) log.scrollTop = log.scrollHeight;
  }
}

async function refresh() {
  try {
    const r = await fetch('/api/status', {cache: 'no-store'});
    if (!r.ok) throw new Error();
    render(await r.json());
    $('offline').classList.add('hidden');
  } catch (e) {
    $('offline').classList.remove('hidden');
    $('dot').className = 'dot';
    $('myname').textContent = '離線';
  }
}

$('pauseBtn').onclick = async () => {
  try {
    await post(paused ? '/api/resume' : '/api/pause');
    toast(paused ? '已恢復同步' : '已暫停同步(兩邊都不會再互傳)');
    refresh();
  } catch (e) { toast('操作失敗:' + e.message); }
};

$('sendBtn').onclick = async () => {
  const text = $('sendText').value;
  if (!text.trim()) { toast('先打點字再送'); return; }
  $('sendBtn').disabled = true;
  try {
    const r = await post('/api/send', {text});
    if (!r.ok) toast(r.msg || '送出失敗');
    else if (r.delivered > 0) { toast('已送到 ' + r.delivered + ' 台電腦'); $('sendText').value = ''; }
    else toast('沒有連上任何電腦,這次沒送出去');
  } catch (e) { toast('送出失敗:' + e.message); }
  $('sendBtn').disabled = false;
  refresh();
};

$('sendText').addEventListener('keydown', e => {
  if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') $('sendBtn').click();
});

$('pushBtn').onclick = async () => {
  try { toast((await post('/api/push')).msg); } catch (e) { toast('失敗:' + e.message); }
  refresh();
};

$('inboxBtn').onclick = async () => {
  try { toast((await post('/api/open-inbox')).msg); } catch (e) { toast('失敗:' + e.message); }
};

refresh();
setInterval(refresh, 2000);
</script>
</body>
</html>
''';
