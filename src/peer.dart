import 'config.dart';
import 'util.dart';

class Peer {
  Peer({
    required this.deviceId,
    required this.name,
    required this.ip,
    required this.contentPort,
    required this.platform,
    required this.protocolVersion,
  })  : lastSeen = DateTime.now(),
        ipLastSeen = DateTime.now();

  final String deviceId;
  String name;
  String ip;
  int contentPort;
  String platform;

  /// 最後一次收到這台裝置的任何心跳(不管從哪個位址來)。用來判斷離線。
  DateTime lastSeen;

  /// 最後一次從**現用位址** [ip] 收到心跳。
  ///
  /// 和 [lastSeen] 分開記是必要的:對方若有兩張網卡,用 lastSeen 判斷
  /// 「現用位址還活著嗎」會永遠是 true —— 另一張網卡的心跳一直在幫它續命,
  /// 於是就算現用位址其實已經拔線,也永遠不會切換過去。
  DateTime ipLastSeen;

  /// 這台裝置還有哪些位址在發心跳。純粹給診斷用(`/status` 會顯示),
  /// 讓「這台電腦同時接了有線和無線」這件事一眼就看得出來。
  final Set<String> altIps = {};

  /// 對方跑的協定版本。版本不合就不要硬送 —— 舊版收到新格式只會回 HTTP 500,
  /// 使用者看到的是一堆看不懂的錯誤,而不是「你該更新了」。
  int protocolVersion;

  /// 版本不合的警告只印一次,不要每次複製都洗版。
  bool versionWarned = false;

  /// TCP 存活確認正在進行中。sweep 看到這個旗標會先不動這台裝置 ——
  /// 不然「sweep 剛把它移除、一秒後 ping 成功」的競態會把 lastSeen
  /// 更新在一個已經不在清單裡的孤兒物件上,裝置就這樣冤枉地消失了。
  bool pingInFlight = false;

  bool get isCompatible => protocolVersion == kProtocolVersion;

  /// 連續送失敗幾次。用來判斷「心跳收得到但內容送不進去」——通常是防火牆
  /// 只擋了 TCP,這在報告裡是個很具體的觀察點。
  int consecutiveFailures = 0;

  String get endpoint => 'http://$ip:$contentPort';

  @override
  String toString() => '$name ($platform) $ip:$contentPort'
      '${altIps.isEmpty ? "" : "  (同一台也從 ${altIps.join("、")} 發心跳)"}'
      '${isCompatible ? "" : "  ⚠ 協定 v$protocolVersion,本機是 v$kProtocolVersion"}'
      '  最後心跳 ${hhmmss(lastSeen)}';
}

/// 裝置清單。之後在 Flutter 裡,這個類別會變成 ChangeNotifier,
/// UI 的「裝置列表」直接吃它 —— 現在先用 callback,概念是一樣的。
class PeerRegistry {
  final Map<String, Peer> _byId = {}; // key: deviceId,不是 IP(IP 會變)

  void Function(Peer peer)? onFound;
  void Function(Peer peer)? onLost;
  void Function(Peer peer, String field)? onChanged;

  Iterable<Peer> get all => _byId.values;
  int get length => _byId.length;
  bool get isEmpty => _byId.isEmpty;

  /// 收到心跳時呼叫。回傳 true 表示這是新裝置。
  bool touch({
    required String deviceId,
    required String name,
    required String ip,
    required int contentPort,
    required String platform,
    required int protocolVersion,
  }) {
    final existing = _byId[deviceId];
    if (existing == null) {
      final p = Peer(
        deviceId: deviceId,
        name: name,
        ip: ip,
        contentPort: contentPort,
        platform: platform,
        protocolVersion: protocolVersion,
      );
      _byId[deviceId] = p;
      onFound?.call(p);
      return true;
    }

    final now = DateTime.now();

    // 同一台裝置換了 Wi-Fi、IP 變了 —— 靠 deviceId 當 key 才接得住這件事。
    //
    // 但「位址不一樣」有兩種完全不同的成因,不能一律照收:
    //   (a) 真的換網路了 —— 舊位址從此再無心跳,該切。
    //   (b) 對方同時接了有線和無線,兩張網卡都在同一個網段 —— 兩個位址
    //       都活著、輪流送心跳。這時每次照收就會每兩秒改寫一次,
    //       清單上兩個 IP 不停互跳(見 kAddressStickiness 的說明)。
    //
    // 分辨方法:現用位址最近還有沒有心跳。有,就是 (b),忽略。
    if (existing.ip != ip) {
      final quiet = now.difference(existing.ipLastSeen);
      // 內容送不出去時不要死守著這個位址 —— 對方另一張網卡也許通。
      final stuck = existing.consecutiveFailures > 0;
      if (quiet > kAddressStickiness || stuck) {
        final old = existing.ip;
        existing.altIps.remove(ip);
        existing.altIps.add(old);
        existing.ip = ip;
        existing.ipLastSeen = now;
        existing.consecutiveFailures = 0; // 換了位址,舊的失敗次數不算數
        onChanged?.call(existing, 'IP $old → $ip');
      } else {
        // 記下來但不切換。只有第一次看到才通知,不然還是會洗版。
        if (existing.altIps.add(ip)) {
          onChanged?.call(existing, '同一台裝置也從 $ip 發心跳(維持用 ${existing.ip})');
        }
      }
    } else {
      existing.ipLastSeen = now;
    }

    if (existing.name != name) {
      existing.name = name;
      onChanged?.call(existing, '改名為 $name');
    }
    existing.contentPort = contentPort;
    existing.platform = platform;
    existing.protocolVersion = protocolVersion;
    existing.lastSeen = now;
    return false;
  }

  /// 清掉太久沒心跳的裝置。正在做 TCP 存活確認的先跳過(見 pingInFlight)。
  void sweep() {
    final now = DateTime.now();
    _byId.removeWhere((_, p) {
      if (p.pingInFlight) return false;
      final dead = now.difference(p.lastSeen) > kPeerTimeout;
      if (dead) onLost?.call(p);
      return dead;
    });
  }

  Peer? byId(String deviceId) => _byId[deviceId];

  /// 這個 IP 是不是某台已知裝置?收到內容時用來擋陌生來源。
  ///
  /// 一定要連 altIps 一起看:對方有兩張網卡時,心跳走的位址和 TCP 連線
  /// 實際用的來源位址不保證相同(送出去時由路由表決定)。只比對現用位址
  /// 的話,內容會被自家的來源檢查擋掉 —— 症狀是「找得到裝置卻收不到東西」。
  bool hasIp(String ip) =>
      _byId.values.any((p) => p.ip == ip || p.altIps.contains(ip));
}
