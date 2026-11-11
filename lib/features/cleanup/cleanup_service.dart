import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../live/live_store.dart';

/// Items of 设置 → 数据清理. OBSERVED in the original's sheet (group 缓存): 图片缓存, 临时文件, 同步缓存, 日志.
/// This project keeps no log files and no sync cache, so it offers its live playlist cache instead of 同步缓存.
enum CleanupItem { images, temp, livePlaylists }

class CleanupService {
  CleanupService({required this.livePlaylists, Future<Directory> Function()? tempDir, void Function()? clearImages})
      : _tempDir = tempDir ?? getTemporaryDirectory,
        _clearImages = clearImages ?? _clearImageCache;

  final LivePlaylistLoader livePlaylists;
  final Future<Directory> Function() _tempDir;
  final void Function() _clearImages;

  /// Copies plugins leave in the app's cache directory: file_picker keeps every picked file (备份恢复, 本地弹幕脚本),
  /// share_plus every shared file (导出备份). The rest of that directory can belong to code that is running
  /// (WebView, the embedded runtime), so it is left alone.
  static const tempSubdirs = ['file_picker', 'share_plus'];

  /// Posters and covers are loaded with Image.network, which caches in memory only.
  static void _clearImageCache() {
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
  }

  /// Clears [items] in a fixed order and returns how many were cleared.
  Future<int> clear(Set<CleanupItem> items) async {
    var done = 0;
    for (final item in CleanupItem.values.where(items.contains)) {
      switch (item) {
        case CleanupItem.images:
          _clearImages();
        case CleanupItem.temp:
          final base = await _tempDir();
          for (final name in tempSubdirs) {
            final dir = Directory(p.join(base.path, name));
            if (await dir.exists()) await dir.delete(recursive: true);
          }
        case CleanupItem.livePlaylists:
          await livePlaylists.clearAll();
      }
      done++;
    }
    return done;
  }
}
