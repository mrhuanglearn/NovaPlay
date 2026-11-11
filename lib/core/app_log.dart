import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'redact.dart';

// 设置 → 功能设置 → 日志记录, OBSERVED on the original (2026-11-09, with the user's consent):
// - A switch, off by default. On, two indented rows appear under it: 清空日志 and 导出日志.
// - The log file is uzData/Data/log.txt. With logging on, opening pages, a detail page, a subscription refresh that
//   failed (「catpaw」检查失败) and a normal exit wrote nothing to it; it stayed at 0 bytes.
// - 导出日志 opens the system save dialog (CREATE_DOCUMENT, text/plain, default name uzn_log.txt) and saves a copy of
//   log.txt (0 bytes then); no message afterwards.
// - 清空日志 asks 清空日志 / 确定清空所有日志记录吗？ (取消 / 清空) and rewrites log.txt empty.
// INFERRED from that and from its strings ("下方为异常详细信息，可在 log.txt 中查看完整日志", "已清理，部分项目失败（详见日志）"):
// the file collects errors, not activity. This project writes uncaught errors with their stack traces.

/// The log file and its writer. One per process ([appLog]); the error hooks in `main()` write through it.
class AppLog {
  AppLog({Future<File> Function()? file, DateTime Function()? clock})
      : _fileOf = file ?? _defaultFile,
        _clock = clock ?? DateTime.now;

  final Future<File> Function() _fileOf;
  final DateTime Function() _clock;

  /// Above this the oldest half is dropped (an error inside a build can repeat every frame).
  static const maxBytes = 512 * 1024;

  static Future<File> _defaultFile() async => File(p.join((await getApplicationSupportDirectory()).path, 'log.txt'));

  bool _enabled = false;
  bool get enabled => _enabled;
  Future<void> _queue = Future<void>.value();

  /// Switching on creates the (empty) file, so 导出日志 works before anything was logged, as in the original.
  Future<void> setEnabled(bool on) {
    _enabled = on;
    if (!on) return Future<void>.value();
    return _serial(() async {
      final f = await _fileOf();
      if (!await f.exists()) await f.create(recursive: true);
    });
  }

  /// Appends an error with its stack trace. Never throws, and does nothing while logging is off.
  Future<void> error(Object error, StackTrace? stack, {String? context}) {
    if (!_enabled) return Future<void>.value();
    final t = _clock();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
    final head = context == null || context.isEmpty ? '$error' : '$context: $error';
    final body = stack == null || stack.toString().trim().isEmpty ? '' : '\n${stack.toString().trimRight()}';
    return _append(redactUrls('$stamp [ERROR] $head$body\n'));
  }

  Future<void> _append(String text) => _serial(() async {
        final f = await _fileOf();
        await f.parent.create(recursive: true);
        await f.writeAsString(text, mode: FileMode.append, flush: true);
        if (await f.length() > maxBytes) {
          final bytes = await f.readAsBytes();
          var cut = bytes.length - maxBytes ~/ 2;
          final nl = bytes.indexOf(0x0A, cut);
          cut = nl < 0 ? cut : nl + 1;
          await f.writeAsBytes(bytes.sublist(cut), flush: true);
        }
      });

  /// The log, or null when there is no file (暂无日志文件).
  Future<Uint8List?> read() async {
    await _queue;
    try {
      final f = await _fileOf();
      return await f.exists() ? await f.readAsBytes() : null;
    } catch (_) {
      return null;
    }
  }

  /// 清空日志: the file stays, empty. False when it could not be written (清理日志失败).
  Future<bool> clear() async {
    var ok = true;
    await _serial(() async {
      try {
        final f = await _fileOf();
        await f.parent.create(recursive: true);
        await f.writeAsBytes(const [], flush: true);
      } catch (_) {
        ok = false;
      }
    });
    return ok;
  }

  /// Runs [job] after the previous one; a failure is swallowed (logging must never take the app down, nor log itself).
  Future<void> _serial(Future<void> Function() job) {
    final next = _queue.then((_) => job()).catchError((Object _) {});
    _queue = next;
    return next;
  }
}

/// The process-wide log; `main()` installs the error hooks on it.
final appLog = AppLog();

/// Sends uncaught errors (framework and asynchronous) to [log], then to the handlers that were there before.
void installErrorLog(AppLog log) {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    unawaited(log.error(details.exception, details.stack, context: details.context?.toDescription()));
    (previous ?? FlutterError.presentError)(details);
  };
  final previousPlatform = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    unawaited(log.error(error, stack));
    return previousPlatform?.call(error, stack) ?? false;
  };
}

final appLogProvider = Provider<AppLog>((ref) => appLog);

/// The name 导出日志 suggests (the original's is uzn_log.txt).
const logExportName = 'novaplay_log.txt';

/// 导出日志: the system save dialog for a text file (OBSERVED CREATE_DOCUMENT, text/plain); null when cancelled.
typedef LogSaver = Future<Uri?> Function(String fileName, Uint8List bytes);

final logSaverProvider = Provider<LogSaver>(
    (ref) => (fileName, bytes) => FilePicker.saveFile(fileName: fileName, bytes: bytes, mimeType: 'text/plain'));
