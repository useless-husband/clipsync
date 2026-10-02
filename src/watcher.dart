// 剪貼簿監看器 —— 這支專案最重要的一個檔案。
//
// 要解決的問題:A 複製 → 寫進 B 的剪貼簿 → B 偵測到「剪貼簿變了」→ 傳回 A
// → A 寫入 → A 又偵測到變了 → 傳給 B …… 無限迴圈,兩台機器互丟到天荒地老。
//
// 解法有三層,由強到弱:
//   1. 【最重要】寫入遠端內容的期間,整個關掉輪詢(_applying 旗標 + 世代計數),
//      寫完之後**重新 probe 一次**把「現在的樣子」記下來。
//      為什麼要重新 probe 而不是自己算 signature?因為檔案同步時,
//      對方傳來的路徑跟我方落地後的路徑**根本不一樣**。問系統最準。
//   2. 靜音期:寫入後 500ms 內偵測到的變化只更新記錄、不往外送。
//   3. 送出端再比一次 signature:同一份內容不重複廣播 → 迴圈必定收斂。

import 'dart:async';
import 'dart:io';

import 'clip_content.dart';
import 'clipboard.dart';
import 'config.dart';

class ClipboardWatcher {
  ClipboardWatcher(this.clipboard, {Duration? interval})
      : interval = interval ?? kClipboardPollInterval;

  final SystemClipboard clipboard;
  final Duration interval;

  /// 使用者自己複製了東西(而不是我們寫進去的)時呼叫。
  void Function(ClipSnapshot snap)? onLocalChange;

  /// 讀不到剪貼簿時回報一次,避免每 700ms 洗一次版。
  void Function(String reason)? onError;

  /// 暫停狀態被外部(旗標檔)改變時通知一聲。
  void Function(bool paused)? onPauseChanged;

  ClipSnapshot? _last;
  DateTime _suppressUntil = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _timer;
  bool _busy = false;     // 上一輪的探測還沒回來就跳過這輪
  bool _applying = false; // 正在寫入遠端內容 → 停止偵測

  /// 世代計數。applyRemote 每動一次剪貼簿就 +1。
  ///
  /// 為什麼需要:_tick 的 probe() 是非同步的,可能跑到一半時 applyRemote
  /// 剛好寫入了新內容 —— 那個 probe 回來的是「寫入前」的舊快照。沒有這個
  /// 檢查的話,舊快照會蓋掉 _last,最壞情況下(Windows 的 probe 特別慢、
  /// 拖過靜音期)還會把**舊內容當成新變化廣播出去**,讓全區網的剪貼簿
  /// 倒退回舊資料。_tick 在 await 前記下世代,回來後發現變了就整包丟棄。
  int _gen = 0;

  /// applyRemote 的序列化佇列。兩個 HTTP 請求同時進來時,兩次剪貼簿寫入
  /// 若平行執行(Windows 上是兩個 PowerShell 程序),完成順序是隨機的 ——
  /// 排進佇列依序做,順序才有意義(訊息新舊由 clipsync.dart 的 seq 檢查把關)。
  Future<void> _applyQueue = Future.value();

  bool _errorReported = false;

  /// 兩種暫停來源:session(--paused,只影響這個程序)與旗標檔(全機器)。
  /// 之前 --paused 會寫入全域旗標檔,結果是「暫停了這台電腦上所有的
  /// ClipSync,而且重開機都還在暫停」—— 使用者只是想這一次先不同步而已。
  bool sessionPaused = false;
  bool _filePaused = false;
  bool get paused => sessionPaused || _filePaused;

  ClipSnapshot? get current => _last;

  Future<void> start() async {
    // 開機時先把「現在剪貼簿裡的東西」記起來。
    // 不做這步的話,程式一啟動就會把你半小時前複製的密碼廣播出去。
    _filePaused = File(pauseFlagPath()).existsSync();
    _last = await clipboard.probe();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 旗標檔是「全機器暫停」的真相來源。existsSync() 只是一次 stat,
  /// 每 700ms 跑一次的成本可以忽略。
  void _syncPauseFlag() {
    final flagged = File(pauseFlagPath()).existsSync();
    if (flagged != _filePaused) {
      _filePaused = flagged;
      onPauseChanged?.call(paused);
    }
  }

  static Future<void> setPaused(bool value) async {
    final f = File(pauseFlagPath());
    try {
      if (value) {
        await f.parent.create(recursive: true);
        await f.writeAsString('paused\n');
      } else if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}
  }

  Future<void> _tick() async {
    if (_busy || _applying) return;
    _syncPauseFlag();
    _busy = true;
    try {
      final genAtStart = _gen;
      final snap = await clipboard.probe();
      // probe 進行期間 applyRemote 動過剪貼簿 → 這個快照已經過時,整包丟棄。
      if (_applying || _gen != genAtStart) return;
      if (snap == null) return; // 空的、或不支援的格式 —— 不算錯誤
      _errorReported = false;

      if (_last != null && snap.signature == _last!.signature) return; // 第 1 層
      _last = snap;

      if (DateTime.now().isBefore(_suppressUntil)) return; // 第 2 層:靜音期
      if (paused) return;

      onLocalChange?.call(snap);
    } catch (e) {
      if (!_errorReported) {
        _errorReported = true;
        onError?.call('讀取剪貼簿失敗($e),先跳過');
      }
    } finally {
      _busy = false;
    }
  }

  /// 把遠端來的內容寫進本機剪貼簿。呼叫會**排隊依序執行**。
  ///
  /// 回傳寫入後重新 probe 到的 signature;null 表示寫入失敗;
  /// 空字串表示寫入成功但 reprobe 失敗(signature 未知)。
  Future<String?> applyRemote(Future<bool> Function() write) {
    final result = _applyQueue.then((_) => _applyOne(write));
    // 佇列本身吞掉錯誤,不然一次失敗會讓後面所有 apply 都掛掉。
    _applyQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<String?> _applyOne(Future<bool> Function() write) async {
    _applying = true;
    _gen++;
    try {
      final ok = await write();
      _suppressUntil = DateTime.now().add(kEchoSuppressWindow);
      // 寫完後重新 probe:記下「系統現在實際上是什麼樣子」,
      // 而不是「我以為我寫進去了什麼」。
      final fresh = await clipboard.probe();
      _gen++;
      if (fresh == null) {
        // reprobe 失敗 → 我們不知道剪貼簿現在的 signature。把靜音期拉長,
        // 讓下一次成功的 probe 只記錄、不廣播,避免把剛收到的內容回聲出去。
        _suppressUntil = DateTime.now().add(const Duration(seconds: 3));
        _last = null;
        return ok ? '' : null;
      }
      _last = fresh;
      return ok ? fresh.signature : null;
    } finally {
      _applying = false;
    }
  }

  /// 使用者手動送出時用:內容沒變就不必再送一次。
  bool isSameAsCurrent(String signature) => _last?.signature == signature;
}
