// UDP 探索層。跟 Step 1 一樣的心跳,但做了兩個升級:
//
//  1. 心跳裡多帶 deviceId 和 contentPort —— 對方要知道「內容要 POST 到哪個 port」。
//  2. 除了 255.255.255.255,還會對每張網卡的「子網廣播位址」各送一份。
//     原因:有些系統(尤其是多網卡:Wi-Fi + 乙太 + VPN + Docker 虛擬網卡)
//     對 255.255.255.255 只會從預設路由那張網卡送出去,另一張就收不到。
//     這是實測時「兩台明明同網段卻看不到彼此」的常見元凶之一。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';
import 'peer.dart';
import 'util.dart';

class Discovery {
  Discovery({
    required this.myDeviceId,
    required this.myName,
    required this.peers,
    required this.contentPortProvider,
  });

  final String myDeviceId;
  final String myName;
  final PeerRegistry peers;

  /// 內容埠可能是動態決定的(53318 被佔用時會退而求其次),
  /// 所以這裡收一個 getter 而不是一個固定的數字。
  final int Function() contentPortProvider;

  void Function(String message)? onLog;

  // ⚠ 收與送刻意用**兩個不同的 socket**。
  //
  // 慘痛教訓:一開始只用一個 socket 同時收送,結果只要有一次 send() 失敗
  // (例如 VPN 介面沒有廣播路由),整個 socket 就毀了 —— 程式還活著,
  // 卻既收不到也送不出,而且完全沒有徵兆。比直接當掉還難查。
  //
  // 拆開之後:_rx 只負責聽,永遠不 send,所以永遠不會因為送出失敗而壞掉;
  // _tx 壞了就丟掉重建,收訊完全不受影響。
  RawDatagramSocket? _rx;
  RawDatagramSocket? _tx;
  Timer? _heartbeatTimer;
  Timer? _sweepTimer;
  Timer? _targetsTimer;
  List<InternetAddress> _broadcastTargets = const [];

  Future<void> start() async {
    await _ensureRx();
    _broadcastTargets = await _computeBroadcastTargets();

    _heartbeatTimer = Timer.periodic(kHeartbeatInterval, (_) => sendHeartbeat());
    await sendHeartbeat();

    _sweepTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      peers.sweep();
      _ensureRx(); // 收訊 socket 若壞掉,在這裡默默接回來
    });

    // 網路狀態會變:開機時網卡還沒起來、換 Wi-Fi、插拔網路線、VPN 上線…
    // 只在啟動時算一次廣播位址的話,這些情況全部接不到。
    _targetsTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      final fresh = await _computeBroadcastTargets();
      if (fresh.length != _broadcastTargets.length) {
        onLog?.call('網路介面有變動,廣播目標更新為 ${fresh.length} 個');
      }
      _broadcastTargets = fresh;
    });
  }

  void stop() {
    _heartbeatTimer?.cancel();
    _sweepTimer?.cancel();
    _targetsTimer?.cancel();
    _rx?.close();
    _tx?.close();
  }

  /// 只收不送的 socket。綁在固定的探索埠上。
  Future<void> _ensureRx() async {
    if (_rx != null) return;
    try {
      final s = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        kDiscoveryPort,
        reuseAddress: true,
        reusePort: !Platform.isWindows, // Windows 不支援 SO_REUSEPORT
      );
      s.listen(
        _onEvent,
        onError: (Object e) {
          onLog?.call('接收 socket 錯誤,將重建:$e');
          // 只有錯誤來自「現任」socket 才動手。舊 socket 被換掉之後,
          // 它殘留的錯誤事件還可能晚到 —— 不比對的話會把剛重建好的
          // 新 socket 誤殺掉。
          if (identical(_rx, s)) _rx = null;
          s.close();
        },
        cancelOnError: false,
      );
      _rx = s;
    } catch (e) {
      onLog?.call('無法綁定 UDP $kDiscoveryPort:$e');
    }
  }

  /// 只送不收的 socket。用系統隨機分配的埠 —— 收端只看來源 IP,不管來源埠。
  /// 壞了就整個丟掉重建,反正它沒有狀態。
  Future<void> _ensureTx() async {
    if (_tx != null) return;
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      s.broadcastEnabled = true;
      s.listen(
        (_) {},
        onError: (Object e) {
          // send() 的失敗是從這裡非同步冒出來的,不是從 send() 本身丟出來。
          debugLog('廣播 socket 錯誤,將重建:$e');
          if (identical(_tx, s)) _tx = null;
          s.close();
        },
        cancelOnError: false,
      );
      _tx = s;
    } catch (e) {
      debugLog('無法建立廣播 socket:$e');
    }
  }

  /// 離線前送一封「我要走了」,對方就不用等 10 秒逾時。
  Future<void> sendGoodbye() {
    return _send({
      'app': kApp,
      'v': kProtocolVersion,
      'type': 'bye',
      'deviceId': myDeviceId,
      'name': myName,
    });
  }

  Future<void> sendHeartbeat() {
    return _send({
      'app': kApp,
      'v': kProtocolVersion,
      'type': 'hello',
      'deviceId': myDeviceId,
      'name': myName,
      'contentPort': contentPortProvider(),
      'platform': Platform.operatingSystem,
    });
  }

  Future<void> _send(Map<String, dynamic> payload) async {
    await _ensureTx();
    final socket = _tx;
    if (socket == null) return;
    final bytes = utf8.encode(jsonEncode(payload));

    // 1) 廣播 —— 用來「找到還不認識的裝置」。
    // 2) 單播給每一個已知裝置 —— 用來「確認他還在」。
    //
    // 為什麼要多這一步:廣播封包在很多環境下掉得很兇(交換器對廣播的處理、
    // 無線 AP 的省電機制、防火牆…),實測有台 Windows 的心跳只有十分之一
    // 穿得過來。但單播是點對點的,可靠得多。既然已經知道對方的 IP 了,
    // 就不該繼續只靠廣播來維持「他還在線上」這件事。
    final targets = <InternetAddress>[
      ..._broadcastTargets,
      for (final p in peers.all) InternetAddress(p.ip),
    ];

    for (final target in targets) {
      try {
        final n = socket.send(bytes, target, kDiscoveryPort);
        debugLog('TX ${payload['type']} → ${target.address}:$kDiscoveryPort '
            '($n/${bytes.length} bytes)');
      } catch (e) {
        // 同步的錯誤(少數情況)。非同步的那種請看 _ensureTx 的 onError。
        debugLog('TX 失敗 → ${target.address}:$e');
      }
    }
  }

  /// VPN、Docker、虛擬機的網卡不能拿來廣播 —— 對它們的子網廣播位址送封包
  /// 會直接噴 "No route to host"。這些介面的命名很有規律,直接跳過。
  ///
  /// (這是實測踩出來的:一開 VPN,utun8 = 10.66.66.1 就出現,
  ///  對 10.66.66.255 廣播必定失敗。)
  static const _virtualPrefixes = [
    'utun', 'ipsec', 'ppp', 'tun', 'tap', // VPN / 通道
    'tailscale', 'wg', 'zt', 'nebula', 'wintun', 'ham', // 常見 overlay VPN
    'awdl', 'llw', // macOS 的 AirDrop / 低延遲無線
    'bridge', 'docker', 'veth', 'vboxnet', 'vmnet', 'virbr', // 虛擬化
  ];

  static bool _isVirtual(String name) =>
      _virtualPrefixes.any((p) => name.toLowerCase().startsWith(p));

  Future<List<InternetAddress>> _computeBroadcastTargets() async {
    final targets = <String>{'255.255.255.255'};
    try {
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in ifaces) {
        if (_isVirtual(iface.name)) {
          debugLog('跳過虛擬介面 ${iface.name}');
          continue;
        }
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;
          // 假設 /24。家用網路幾乎都是,但學校可能是 /16 —— 這是已知的簡化,
          // 真正嚴謹的做法要讀網路遮罩(Dart 目前沒直接給,得走 FFI 或 ip 指令)。
          targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
        }
      }
    } catch (_) {}
    return [for (final t in targets) InternetAddress(t)];
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _rx;
    if (socket == null) return;
    final dg = socket.receive();
    if (dg == null) return;
    debugLog('RX ${dg.data.length} bytes from ${dg.address.address}');

    // 整段包 try:封包內容是任何人都能偽造的。欄位型別不對(name 放數字、
    // contentPort 放字串)的 as-cast 會丟 TypeError —— 沒接住的話,
    // 一台亂送封包的機器就能讓這裡每 2 秒噴一次未捕捉例外。
    try {
      _handlePacket(dg);
    } catch (e) {
      debugLog('封包解析失敗(已忽略):$e');
    }
  }

  void _handlePacket(Datagram dg) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(dg.data));
    } catch (_) {
      return; // 不是 JSON,不是我們的東西
    }
    if (decoded is! Map) return;
    if (decoded['app'] != kApp) return;

    final deviceId = decoded['deviceId'];
    // 沒有 deviceId 的是 Step 1 的舊版封包;有的話,自己的廣播直接跳過。
    if (deviceId is! String || deviceId.isEmpty || deviceId == myDeviceId) {
      return;
    }

    switch (decoded['type']) {
      case 'hello':
        final rawName =
            (decoded['name'] is String ? decoded['name'] as String : '').trim();
        peers.touch(
          deviceId: deviceId,
          // 舊版的啟動器有機會傳空字串當名字,顯示成空白很難認 —— 補一個代稱。
          name: rawName.isEmpty ? '(未命名裝置)' : rawName,
          ip: dg.address.address,
          contentPort: (decoded['contentPort'] is num
                  ? (decoded['contentPort'] as num).toInt()
                  : kContentPort)
              .clamp(1, 65535),
          platform:
              decoded['platform'] is String ? decoded['platform'] as String : '?',
          protocolVersion:
              decoded['v'] is num ? (decoded['v'] as num).toInt() : 1,
        );
        break;

      case 'bye':
        final p = peers.byId(deviceId);
        if (p != null) {
          p.lastSeen = DateTime.fromMillisecondsSinceEpoch(0);
          peers.sweep();
        }
        break;
    }
  }
}
