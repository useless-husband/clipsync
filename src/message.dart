import 'dart:convert';

import 'clip_content.dart';
import 'config.dart';

/// 一則內容的中繼資料。
///
/// v3 起,這東西不再是 HTTP body,而是塞在 `x-clipsync-meta` 標頭裡(base64
/// 過的 JSON),body 完全留給原始位元組。理由:圖片和檔案如果塞進 JSON 要先
/// base64,體積膨脹 33%,而且整包都得先進記憶體才能解析。
///
/// 多檔傳輸的做法:**一個檔案一個 POST**,靠 transferId + index/count 兜回來。
/// 不用「先送清單再送檔案」的兩階段協定,是因為這樣少一種失敗狀態要處理。
class ClipMeta {
  ClipMeta({
    required this.kind,
    required this.fromName,
    required this.fromDeviceId,
    required this.signature,
    required this.seq,
    required this.sentAtMs,
    this.mime = 'application/octet-stream',
    this.transferId,
    this.index = 0,
    this.count = 1,
    this.name,
    this.size = 0,
    this.totalBytes = 0,
  });

  final ClipKind kind;
  final String fromName;
  final String fromDeviceId;

  /// 送出端剪貼簿的 signature。收端拿來擋重複,不是拿來當本地 signature 用
  /// ——本地的要重新 probe 才準(檔案路徑會不一樣)。
  final String signature;

  final int seq;
  final int sentAtMs;
  final String mime;

  // 以下只有 kind == files 時有意義
  final String? transferId;
  final int index;
  final int count;
  final String? name;
  final int size;
  final int totalBytes;

  Map<String, dynamic> toJson() => {
        'app': kApp,
        'v': kProtocolVersion,
        'kind': clipKindName(kind),
        'from': fromName,
        'deviceId': fromDeviceId,
        'sig': signature,
        'seq': seq,
        'ts': sentAtMs,
        'mime': mime,
        if (transferId != null) 'tid': transferId,
        if (kind == ClipKind.files) ...{
          'i': index,
          'n': count,
          'name': name,
          'size': size,
          'total': totalBytes,
        },
      };

  String encodeHeader() => base64.encode(utf8.encode(jsonEncode(toJson())));

  /// 寬鬆解析:欄位不對就回 null,不要讓一個壞封包把整個程式弄掛。
  static ClipMeta? decodeHeader(String? header) {
    if (header == null || header.isEmpty) return null;
    try {
      final decoded = jsonDecode(utf8.decode(base64.decode(header)));
      if (decoded is! Map) return null;
      if (decoded['app'] != kApp) return null;

      final kind = clipKindFrom(decoded['kind'] as String?);
      final deviceId = decoded['deviceId'] as String?;
      if (kind == null || deviceId == null || deviceId.isEmpty) return null;

      return ClipMeta(
        kind: kind,
        fromName: decoded['from'] as String? ?? '?',
        fromDeviceId: deviceId,
        signature: decoded['sig'] as String? ?? '',
        seq: (decoded['seq'] as num?)?.toInt() ?? 0,
        sentAtMs: (decoded['ts'] as num?)?.toInt() ?? 0,
        mime: decoded['mime'] as String? ?? 'application/octet-stream',
        transferId: decoded['tid'] as String?,
        index: (decoded['i'] as num?)?.toInt() ?? 0,
        count: (decoded['n'] as num?)?.toInt() ?? 1,
        name: decoded['name'] as String?,
        size: (decoded['size'] as num?)?.toInt() ?? 0,
        totalBytes: (decoded['total'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}
