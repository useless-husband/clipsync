// ClipSync — Step 1: LAN 裝置探索 + 文字互傳(最小原型)
//
// 跑法(兩台同一 Wi-Fi 的電腦各開一個終端機):
//   dart run discovery.dart Alice
//   dart run discovery.dart Bob
// 幾秒內雙方會互相印出「發現裝置」。
// 之後在任一邊打字按 Enter,另一邊會印出來 —— 這就是剪貼簿同步的核心迴圈雛形。
//
// 原理:
//   1. 每台裝置每 2 秒對區網廣播位址 255.255.255.255:53317 丟一個 JSON 心跳
//      {"app":"clipsync","name":"Alice","port":53317}
//   2. 同時監聽同一個 port,收到別人的心跳就記進 peers 清單
//   3. 打字送出時,對每個 peer 的 IP「單播」一個 {"app":"clipsync","type":"clip","text":...}
//
// 之後的每一步(mDNS、加密、真的讀剪貼簿)都是在這個骨架上換零件。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const int kPort = 53317; // LocalSend 也用這個 port,致敬一下
const String kApp = 'clipsync';

final Map<String, Peer> peers = {}; // key: ip

class Peer {
  final String ip;
  final String name;
  DateTime lastSeen;
  Peer(this.ip, this.name) : lastSeen = DateTime.now();
}

late String myName;
late RawDatagramSocket socket;

Future<void> main(List<String> args) async {
  myName = args.isNotEmpty ? args[0] : Platform.localHostname;

  // 一個 socket 同時負責:廣播心跳、收心跳、收/發文字訊息
  socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, kPort,
      reuseAddress: true, reusePort: !Platform.isWindows);
  socket.broadcastEnabled = true;

  print('[$myName] 已啟動,監聽 UDP $kPort,開始尋找同區網的夥伴…');
  print('提示:打一段文字按 Enter,會送到所有已發現的裝置。\n');

  socket.listen(_onSocketEvent);

  // 每 2 秒廣播一次「我在這」
  Timer.periodic(const Duration(seconds: 2), (_) => _sendHeartbeat());
  _sendHeartbeat();

  // 每 5 秒清掉 10 秒沒回音的裝置(斷線偵測)
  Timer.periodic(const Duration(seconds: 5), (_) {
    final now = DateTime.now();
    peers.removeWhere((ip, p) {
      final dead = now.difference(p.lastSeen).inSeconds > 10;
      if (dead) print('✗ 裝置離線:${p.name} ($ip)');
      return dead;
    });
  });

  // 讀鍵盤輸入 → 單播給每個 peer(這行以後會被「剪貼簿變化」取代)
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    if (line.trim().isEmpty) return;
    if (peers.isEmpty) {
      print('(還沒發現任何裝置,先等心跳互通)');
      return;
    }
    final msg = utf8.encode(jsonEncode({
      'app': kApp,
      'type': 'clip',
      'from': myName,
      'text': line,
    }));
    for (final p in peers.values) {
      socket.send(msg, InternetAddress(p.ip), kPort);
    }
    print('→ 已送出給 ${peers.length} 台裝置');
  });
}

void _sendHeartbeat() {
  final msg = utf8.encode(jsonEncode({
    'app': kApp,
    'type': 'hello',
    'name': myName,
  }));
  socket.send(msg, InternetAddress('255.255.255.255'), kPort);
}

void _onSocketEvent(RawSocketEvent event) {
  if (event != RawSocketEvent.read) return;
  final dg = socket.receive();
  if (dg == null) return;

  final ip = dg.address.address;

  Map<String, dynamic> data;
  try {
    data = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
  } catch (_) {
    return; // 不是 JSON,不理它
  }
  if (data['app'] != kApp) return; // 不是我們的封包

  switch (data['type']) {
    case 'hello':
      final name = data['name'] as String? ?? '?';
      if (name == myName) return; // 自己的廣播,跳過(回音防護第一課!)
      final isNew = !peers.containsKey(ip);
      peers[ip] = (peers[ip]?..lastSeen = DateTime.now()) ?? Peer(ip, name);
      if (isNew) print('✓ 發現裝置:$name ($ip)');
      break;

    case 'clip':
      final from = data['from'] as String? ?? '?';
      if (from == myName) return;
      print('📋 [$from] ${data['text']}');
      // ← 之後這裡改成「寫入本機剪貼簿」,整個核心迴圈就完成了
      break;
  }
}
