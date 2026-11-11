import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/app_preferences.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/app/theme.dart';
import 'package:uzv_reimpl/app/ui_hooks.dart';
import 'package:uzv_reimpl/core/app_log.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/player/player_launcher.dart';
import 'package:uzv_reimpl/l10n/l10n.dart';
import 'package:uzv_reimpl/ui/preference_screens.dart';

void main() {
  group('AppLog (log.txt)', () {
    late Directory dir;
    late File file;
    AppLog make({DateTime Function()? clock}) =>
        AppLog(file: () async => file, clock: clock ?? () => DateTime(2026, 11, 9, 8, 5, 3, 7));

    setUp(() {
      dir = Directory.systemTemp.createTempSync('uzv_log_');
      file = File('${dir.path}/log.txt');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('off: nothing is written and there is no file', () async {
      final log = make();
      await log.error(StateError('x'), StackTrace.current);
      expect(file.existsSync(), isFalse);
      expect(await log.read(), isNull);
    });

    test('switching on creates the empty file (导出日志 has something to save); off keeps it', () async {
      final log = make();
      await log.setEnabled(true);
      expect(log.enabled, isTrue);
      expect(file.lengthSync(), 0);
      expect(await log.read(), isEmpty);
      await log.setEnabled(false);
      expect(file.existsSync(), isTrue);
      await log.error(StateError('ignored'), null);
      expect(file.lengthSync(), 0);
    });

    test('an entry: time, level, context, error, stack; credentials in URLs are removed', () async {
      final log = make();
      await log.setEnabled(true);
      await log.error(StateError('GET https://user:secret@host.example/index.js failed'),
          StackTrace.fromString('#0 main (file:///a.dart:1)\n#1 run (file:///b.dart:2)\n'),
          context: 'while building Foo');
      await log.error(const FormatException('bad'), null);
      expect(
          utf8.decode((await log.read())!),
          '2026-11-09 08:05:03.007 [ERROR] while building Foo: Bad state: GET https://host.example/index.js failed\n'
          '#0 main (file:///a.dart:1)\n#1 run (file:///b.dart:2)\n'
          '2026-11-09 08:05:03.007 [ERROR] FormatException: bad\n');
      expect(file.readAsStringSync(), isNot(contains('secret')));
    });

    test('writes fired together land whole and in order', () async {
      final log = make();
      await log.setEnabled(true);
      for (var i = 0; i < 50; i++) {
        log.error('e$i', null);
      }
      final lines = const LineSplitter().convert(utf8.decode((await log.read())!));
      expect(lines.map((l) => l.split(' ').last), [for (var i = 0; i < 50; i++) 'e$i']);
    });

    test('above maxBytes the oldest half goes, cut at a line', () async {
      final log = make();
      await log.setEnabled(true);
      final pad = 'x' * 1000;
      for (var i = 0; i < 600; i++) {
        await log.error('e$i $pad', null);
      }
      final text = utf8.decode((await log.read())!);
      expect(text.length, lessThanOrEqualTo(AppLog.maxBytes));
      expect(text, startsWith('2026-11-09 08:05:03.007 [ERROR] e'));
      expect(text, endsWith('e599 $pad\n'));
      expect(text, isNot(contains('[ERROR] e0 ')));
    });

    test('清空日志 leaves an empty file; a file that cannot be written reports failure without throwing', () async {
      final log = make();
      await log.setEnabled(true);
      await log.error('x', null);
      expect(await log.clear(), isTrue);
      expect(file.lengthSync(), 0);

      File('${dir.path}/blocker').writeAsStringSync('not a folder');
      file = File('${dir.path}/blocker/log.txt');
      expect(await log.clear(), isFalse);
      await log.error('still fine', null);
      expect(await log.read(), isNull);
    });

    test('installErrorLog logs framework and async errors and keeps the previous handlers', () async {
      final savedFlutter = FlutterError.onError;
      final savedPlatform = PlatformDispatcher.instance.onError;
      addTearDown(() {
        FlutterError.onError = savedFlutter;
        PlatformDispatcher.instance.onError = savedPlatform;
      });
      final seen = <Object>[];
      FlutterError.onError = (d) => seen.add(d.exception);
      PlatformDispatcher.instance.onError = (e, s) {
        seen.add(e);
        return true;
      };
      final log = make();
      await log.setEnabled(true);
      installErrorLog(log);

      FlutterError.reportError(FlutterErrorDetails(
          exception: StateError('frame'), stack: StackTrace.current, context: ErrorDescription('while building X')));
      expect(PlatformDispatcher.instance.onError!(StateError('async'), StackTrace.current), isTrue);
      expect(seen.map((e) => '$e'), ['Bad state: frame', 'Bad state: async']);
      final text = utf8.decode((await log.read())!);
      expect(text, contains('[ERROR] while building X: Bad state: frame\n#0 '));
      expect(text, contains('[ERROR] Bad state: async\n#0 '));
    });
  });

  group('日志记录 preference', () {
    test('off by default; saved as "logging"; kept by copyWith and withLockHash', () {
      expect(const AppPreferences().loggingEnabled, isFalse);
      expect(AppPreferences.fromJson(const {}).loggingEnabled, isFalse);
      expect(AppPreferences.fromJson(const {'logging': 'yes'}).loggingEnabled, isFalse);
      const on = AppPreferences(loggingEnabled: true);
      expect(on.toJson()['logging'], isTrue);
      expect(AppPreferences.fromJson(on.toJson()), on);
      expect(on == const AppPreferences(), isFalse);
      expect(on.copyWith(textScale: 1.2).loggingEnabled, isTrue);
      expect(on.withLockHash('h').loggingEnabled, isTrue);
      expect(const AppPreferences().copyWith(loggingEnabled: true).loggingEnabled, isTrue);
    });

    test('switching it saves settings.json and turns the log on or off; other changes leave the log alone', () async {
      final store = _MemoryStore('settings.json');
      final log = _FakeLog();
      final container = ProviderContainer(
          overrides: [settingsStoreProvider.overrideWithValue(store), appLogProvider.overrideWithValue(log)]);
      addTearDown(container.dispose);
      final n = container.read(appPreferencesProvider.notifier);
      await n.update(container.read(appPreferencesProvider).copyWith(loggingEnabled: true));
      expect(log.enabledCalls, [true]);
      expect((await store.read<Map<String, dynamic>>(const {}))['logging'], isTrue);
      await n.update(container.read(appPreferencesProvider).copyWith(textScale: 1.1));
      expect(log.enabledCalls, [true]);
      await n.update(container.read(appPreferencesProvider).copyWith(loggingEnabled: false));
      expect(log.enabledCalls, [true, false]);
      expect((await store.read<Map<String, dynamic>>(const {}))['logging'], isFalse);
    });
  });

  group('功能设置 page', () {
    Future<ProviderContainer> pump(WidgetTester tester, _FakeLog log,
        {bool logging = false, List<(String, Uint8List)>? saved}) async {
      final container = ProviderContainer(overrides: [
        settingsStoreProvider.overrideWithValue(_MemoryStore('settings.json')),
        initialAppPreferencesProvider.overrideWithValue(AppPreferences(loggingEnabled: logging)),
        appLogProvider.overrideWithValue(log),
        playerConfigRepositoryProvider
            .overrideWithValue(PlayerConfigRepository(store: _MemoryStore('player_config.json'))),
        logSaverProvider.overrideWithValue((name, bytes) async {
          saved?.add((name, bytes));
          return Uri.parse('content://saved');
        }),
      ]);
      addTearDown(container.dispose);
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          scaffoldMessengerKey: rootMessengerKey,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildAppTheme(Brightness.dark),
          home: const FeatureSettingsScreen(),
        ),
      ));
      await tester.pumpAndSettle();
      return container;
    }

    double top(WidgetTester tester, String text) => tester.getTopLeft(find.text(text)).dy;

    testWidgets('日志记录 sits between 触感反馈 and catpaw 服务超时; its two rows show only while it is on', (tester) async {
      final log = _FakeLog();
      final container = await pump(tester, log);
      expect(top(tester, '触感反馈'), lessThan(top(tester, '日志记录')));
      expect(top(tester, '日志记录'), lessThan(top(tester, 'catpaw 服务超时')));
      expect(find.text('清空日志'), findsNothing);
      expect(find.text('导出日志'), findsNothing);

      await tester.tap(find.text('日志记录'));
      await tester.pumpAndSettle();
      expect(container.read(appPreferencesProvider).loggingEnabled, isTrue);
      expect(log.enabledCalls, [true]);
      expect(top(tester, '日志记录'), lessThan(top(tester, '清空日志')));
      expect(top(tester, '清空日志'), lessThan(top(tester, '导出日志')));
      expect(top(tester, '导出日志'), lessThan(top(tester, 'catpaw 服务超时')));
      // OBSERVED: the two rows are indented under it.
      expect(tester.getTopLeft(find.text('清空日志')).dx - tester.getTopLeft(find.text('日志记录')).dx, 20);
      expect(find.byIcon(Icons.cleaning_services_outlined), findsOneWidget);
      expect(find.byIcon(Icons.ios_share), findsOneWidget);

      await tester.tap(find.byType(Switch).at(1));
      await tester.pumpAndSettle();
      expect(container.read(appPreferencesProvider).loggingEnabled, isFalse);
      expect(log.enabledCalls, [true, false]);
      expect(find.text('清空日志'), findsNothing);
    });

    testWidgets('清空日志 asks first, with both buttons in the text colour; 取消 keeps the log', (tester) async {
      final log = _FakeLog(content: Uint8List.fromList(utf8.encode('x\n')));
      await pump(tester, log, logging: true);
      await tester.tap(find.text('清空日志'));
      await tester.pumpAndSettle();
      expect(find.text('确定清空所有日志记录吗？'), findsOneWidget);
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('清空日志')), findsOneWidget);
      final label = AppColors.of(tester.element(find.byType(AlertDialog))).label;
      for (final b in ['取消', '清空']) {
        final style = tester.widget<TextButton>(find.widgetWithText(TextButton, b)).style!;
        expect(style.foregroundColor!.resolve({}), label);
      }
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(log.clears, 0);

      await tester.tap(find.text('清空日志'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(log.clears, 1);
      expect(find.text('日志已清空'), findsOneWidget);
    });

    testWidgets('清空日志 that fails says so', (tester) async {
      final log = _FakeLog(content: Uint8List(0), clearOk: false);
      await pump(tester, log, logging: true);
      await tester.tap(find.text('清空日志'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('清理日志失败'), findsOneWidget);
    });

    testWidgets('导出日志 hands the log to the save dialog as novaplay_log.txt, with no message', (tester) async {
      final bytes = Uint8List.fromList(utf8.encode('2026-11-09 [ERROR] x\n'));
      final saved = <(String, Uint8List)>[];
      await pump(tester, _FakeLog(content: bytes), logging: true, saved: saved);
      await tester.tap(find.text('导出日志'));
      await tester.pumpAndSettle();
      expect(saved.single.$1, 'novaplay_log.txt');
      expect(saved.single.$2, bytes);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('导出日志 without a log file says 暂无日志文件', (tester) async {
      final saved = <(String, Uint8List)>[];
      await pump(tester, _FakeLog(), logging: true, saved: saved);
      await tester.tap(find.text('导出日志'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(saved, isEmpty);
      expect(find.text('暂无日志文件'), findsOneWidget);
    });
  });
}

/// The log in memory (widget tests run on a fake clock where real file I/O never completes).
class _FakeLog extends AppLog {
  _FakeLog({this.content, this.clearOk = true});
  Uint8List? content;
  final bool clearOk;
  final enabledCalls = <bool>[];
  int clears = 0;

  @override
  Future<void> setEnabled(bool on) async => enabledCalls.add(on);

  @override
  Future<Uint8List?> read() async => content;

  @override
  Future<bool> clear() async {
    clears++;
    if (clearOk) content = Uint8List(0);
    return clearOk;
  }
}

class _MemoryStore extends JsonStore {
  _MemoryStore(super.name);
  Object? _data;

  @override
  Future<T> read<T>(T fallback) async => (_data as T?) ?? fallback;

  @override
  Future<void> write(Object? json) async => _data = json;
}
