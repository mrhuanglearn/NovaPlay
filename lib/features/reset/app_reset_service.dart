import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 设置 → 重置应用. OBSERVED in the original: the confirm text "将清空所有本地数据（订阅、历史、收藏、设置、字体、catpaw
/// 实例数据等全部内容）并重启应用，相当于恢复出厂", and the strings "开始重置应用（清空 uzData）", "正在重置…",
/// "所有数据已清空，应用将退出，请重新打开。" and "重置失败，请重试".
///
/// Everything this app keeps is inside its own directories: on Android the app-support directory (files/: the JSON
/// stores, installed subscription scripts, downloads, the live playlist cache, the Node project and catpaw's
/// node-data), the temporary directory (cache/) and the documents directory (app_flutter/). Their contents are deleted.
/// Exported backups are written to external storage (`Android/data/<package>/files/Backups`, or `Backups` in the
/// documents directory when there is none) and are kept, so a reset can be followed by a restore (INFERRED: the
/// original's text says 全部内容).
class AppResetService {
  AppResetService(
      {Future<List<Directory>> Function()? dirs, Future<void> Function()? clearWebView, void Function()? stopWriters})
      : _dirs = dirs ?? _appDirs,
        _clearWebView = clearWebView ?? _clearWebViewData,
        _stopWriters = stopWriters ?? _noop;

  final Future<List<Directory>> Function() _dirs;
  final Future<void> Function() _clearWebView;
  final void Function() _stopWriters;

  static void _noop() {}

  static Future<List<Directory>> _appDirs() async =>
      [await getApplicationSupportDirectory(), await getTemporaryDirectory(), await getApplicationDocumentsDirectory()];

  /// Cookies, local storage and cache of the sniffer and web pages.
  static Future<void> _clearWebViewData() async {
    await CookieManager.instance().deleteAllCookies();
    await WebStorageManager.instance().deleteAllData();
    await InAppWebViewController.clearAllCache();
  }

  /// Stops what writes in the background (downloads), clears the WebView data and deletes the app's files.
  Future<void> reset() async {
    _stopWriters();
    try {
      await _clearWebView();
    } catch (_) {
      // Best effort: the WebView may never have been created. Its files are not part of the directories below.
    }
    await wipe();
  }

  /// Folder name of exported backups (see `BackupScreen`); kept wherever it is found.
  static const backupsFolder = 'Backups';

  /// Deletes everything inside the app's directories except [backupsFolder]. Links are removed, not followed. Every
  /// entry is tried; the first failure is rethrown afterwards. Also run right before the process ends, for anything
  /// written in between.
  Future<void> wipe() async {
    Object? failure;
    for (final dir in await _dirs()) {
      if (!await dir.exists()) continue;
      await for (final entry in dir.list(followLinks: false)) {
        if (p.basename(entry.path) == backupsFolder) continue;
        try {
          await entry.delete(recursive: true);
        } catch (e) {
          failure ??= e;
        }
      }
    }
    if (failure != null) throw failure;
  }
}
