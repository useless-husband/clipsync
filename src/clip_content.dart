import 'dart:io';

/// 剪貼簿裡可能放的東西。
enum ClipKind { text, image, files }

String clipKindName(ClipKind k) => switch (k) {
      ClipKind.text => 'text',
      ClipKind.image => 'image',
      ClipKind.files => 'files',
    };

ClipKind? clipKindFrom(String? s) => switch (s) {
      'text' => ClipKind.text,
      'image' => ClipKind.image,
      'files' => ClipKind.files,
      _ => null,
    };

class ClipFileRef {
  const ClipFileRef({required this.path, required this.name, required this.size});

  final String path;
  final String name;
  final int size;

  static ClipFileRef? fromPath(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      return ClipFileRef(
        path: path,
        name: path.split(Platform.pathSeparator).last,
        size: f.lengthSync(),
      );
    } catch (_) {
      return null;
    }
  }
}

/// 「現在剪貼簿長什麼樣」的**輕量**快照。
///
/// 刻意不含圖片的實際位元組:輪詢每 700ms 就要做一次,每次都把 5MB 的圖
/// 讀出來太浪費。所以圖片這裡只留 signature(裡面含位元組數),
/// 真的變了才呼叫 readImageBytes() 去拿。
///
/// signature 的約定:**同一份內容 → 同一個字串**。它就是回音防護在比對的東西。
class ClipSnapshot {
  const ClipSnapshot({
    required this.kind,
    required this.signature,
    this.text,
    this.files = const [],
  });

  final ClipKind kind;
  final String signature;
  final String? text;
  final List<ClipFileRef> files;

  int get totalFileBytes => files.fold(0, (a, f) => a + f.size);

  String describe() => switch (kind) {
        ClipKind.text => '文字',
        ClipKind.image => '圖片',
        ClipKind.files => '${files.length} 個檔案',
      };
}
