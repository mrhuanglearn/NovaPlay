import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/app/theme.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/fonts/font_library.dart';
import 'package:uzv_reimpl/l10n/l10n.dart';
import 'package:uzv_reimpl/ui/preference_screens.dart';

/// 'OTTO' (OpenType CFF) followed by filler; [seed] makes the content (and so the md5) differ.
Uint8List otf([int seed = 1]) => Uint8List.fromList([0x4F, 0x54, 0x54, 0x4F, ...List.filled(60, seed)]);
String idOf(Uint8List bytes) => md5.convert(bytes).toString();

/// Font files in memory; [register] records what the engine was given.
class _Files extends FontFiles {
  final files = <String, Uint8List>{};
  final registered = <String>[];
  var writes = 0;
  bool failRegister = false;

  @override
  Future<void> write(String fileName, Uint8List bytes) async {
    writes++;
    files[fileName] = bytes;
  }

  @override
  Future<Uint8List?> read(String fileName) async => files[fileName];

  @override
  Future<void> delete(String fileName) async => files.remove(fileName);

  @override
  Future<void> register(String family, Uint8List bytes) async {
    if (failRegister) throw Exception('bad font');
    registered.add(family);
  }
}

class _MemoryStore extends JsonStore {
  _MemoryStore() : super('fonts.json');
  Object? data;

  @override
  Future<T> read<T>(T fallback) async => (data as T?) ?? fallback;

  @override
  Future<void> write(Object? json) async => data = json;
}

void main() {
  group('font files', () {
    test('only TrueType / OpenType / collection data counts as a font', () {
      expect(looksLikeFont(otf()), isTrue);
      expect(looksLikeFont(Uint8List.fromList([0, 1, 0, 0, ...List.filled(20, 0)])), isTrue);
      expect(looksLikeFont(Uint8List.fromList([...'true'.codeUnits, ...List.filled(20, 0)])), isTrue);
      expect(looksLikeFont(Uint8List.fromList([...'ttcf'.codeUnits, ...List.filled(20, 0)])), isTrue);
      expect(looksLikeFont(Uint8List.fromList('this is not a font file'.codeUnits)), isFalse);
      expect(looksLikeFont(Uint8List.fromList([0x4F, 0x54, 0x54, 0x4F])), isFalse);
    });

    test('fontSettings JSON: round trip; bad entries, foreign paths and an unknown selection are dropped', () {
      final a = idOf(otf(1)), b = idOf(otf(2));
      final s = FontSettings(selectedId: b, fonts: [
        UserFont(id: a, name: 'A', fileName: '$a.otf'),
        UserFont(id: b, name: 'B', fileName: '$b.ttf'),
      ]);
      final back = FontSettings.fromJson(s.toJson());
      expect(back.fonts.map((f) => (f.id, f.name, f.fileName)), [(a, 'A', '$a.otf'), (b, 'B', '$b.ttf')]);
      expect(back.selectedId, b);
      expect(back.fontFamily, 'uzv_user_$b');

      final messy = FontSettings.fromJson({
        'selected': 'f' * 32,
        'fonts': [
          {'id': a, 'name': 'A', 'file': '$a.otf'},
          {'id': a, 'name': 'again', 'file': '$a.otf'},
          {'id': 'not-hex', 'name': 'X', 'file': 'not-hex.otf'},
          {'id': b, 'name': 'B', 'file': '../$b.otf'},
          'junk',
        ],
      });
      expect(messy.fonts.map((f) => f.name), ['A']);
      expect(messy.selectedId, isNull);
      expect(FontSettings.fromJson('junk').fonts, isEmpty);
      expect(FontSettings.fromJson({'fonts': 'x'}).fonts, isEmpty);
    });

    test('start: every font is registered once; a missing or broken file drops the font and its selection', () async {
      final files = _Files();
      final a = idOf(otf(1)), b = idOf(otf(2));
      files.files['$a.otf'] = otf(1);
      final saved = FontSettings(selectedId: b, fonts: [
        UserFont(id: a, name: 'A', fileName: '$a.otf'),
        UserFont(id: b, name: 'B', fileName: '$b.otf'),
      ]);
      final restored = await restoreFonts(saved, files);
      expect(restored.fonts.map((f) => f.id), [a]);
      expect(restored.selectedId, isNull);
      expect(files.registered, ['uzv_user_$a']);

      final ok = FontSettings(selectedId: a, fonts: [restored.fonts.single]);
      expect(identical(await restoreFonts(ok, files), ok), isTrue);
      expect(files.registered, ['uzv_user_$a'], reason: 'a family is handed to the engine only once');

      final broken = _Files()..failRegister = true;
      broken.files['$a.otf'] = otf(1);
      expect((await restoreFonts(ok, broken)).fonts, isEmpty);
    });
  });

  group('FontSettingsNotifier', () {
    late _Files files;
    late _MemoryStore store;
    late ProviderContainer c;
    setUp(() {
      files = _Files();
      store = _MemoryStore();
      c = ProviderContainer(
          overrides: [fontFilesProvider.overrideWithValue(files), fontsStoreProvider.overrideWithValue(store)]);
    });
    tearDown(() => c.dispose());
    FontSettingsNotifier n() => c.read(fontSettingsProvider.notifier);
    FontSettings s() => c.read(fontSettingsProvider);

    test('import: <md5>.<ext>, named after the file, registered first, not selected, saved', () async {
      final bytes = otf();
      final id = idOf(bytes);
      expect(await n().importFont('Comfortaa-Regular.OTF', bytes), FontImportResult.imported);
      expect(files.files.keys, ['$id.otf']);
      expect(files.registered, ['uzv_user_$id']);
      expect(s().fonts.single.name, 'Comfortaa-Regular');
      expect(s().selectedId, isNull);
      expect(FontSettings.fromJson(store.data).fonts.single.id, id);
    });

    test('the same content again is 该字体已存在, whatever its name; nothing is written', () async {
      await n().importFont('a.ttf', otf());
      expect(await n().importFont('copy.otf', otf()), FontImportResult.exists);
      expect(files.writes, 1);
      expect(s().fonts, hasLength(1));
    });

    test('字体导入失败: wrong extension, not a font, or the engine refuses it; nothing is kept', () async {
      expect(await n().importFont('a.woff', otf()), FontImportResult.failed);
      expect(await n().importFont('a.ttf', Uint8List.fromList('<html>not a font</html>'.codeUnits)),
          FontImportResult.failed);
      expect(files.writes, 0);
      files.failRegister = true;
      expect(await n().importFont('a.ttf', otf()), FontImportResult.failed);
      expect(files.files, isEmpty);
      expect(s().fonts, isEmpty);
    });

    test('select, then delete: deleting the chosen font goes back to 默认 and removes its file', () async {
      await n().importFont('A.ttf', otf(1));
      await n().importFont('B.otf', otf(2));
      final a = s().fonts.first, b = s().fonts.last;
      await n().select(b.id);
      expect(s().fontFamily, b.family);
      await n().delete(a);
      expect(s().selectedId, b.id, reason: 'deleting another font keeps the choice');
      await n().delete(b);
      expect(s().selectedId, isNull);
      expect(s().fonts, isEmpty);
      expect(files.files, isEmpty);
      expect(FontSettings.fromJson(store.data).fonts, isEmpty);
      await n().select('0' * 32);
      expect(s().selectedId, isNull, reason: 'an unknown id is ignored');
    });
  });

  test('the theme carries the chosen family, and each family has its own cached theme', () {
    final plain = buildAppTheme(Brightness.dark);
    final withFont = buildAppTheme(Brightness.dark, fontFamily: 'uzv_user_x');
    expect(identical(plain, buildAppTheme(Brightness.dark)), isTrue);
    expect(identical(plain, withFont), isFalse);
    expect(withFont.textTheme.bodyMedium!.fontFamily, 'uzv_user_x');
    expect(identical(withFont, buildAppTheme(Brightness.dark, fontFamily: 'uzv_user_x')), isTrue);
  });

  group('字体 card', () {
    Future<(ProviderContainer, _Files)> pump(WidgetTester tester, {List<PickedFont?> picks = const []}) async {
      final files = _Files();
      final queue = [...picks];
      final container = ProviderContainer(overrides: [
        fontFilesProvider.overrideWithValue(files),
        fontsStoreProvider.overrideWithValue(_MemoryStore()),
        settingsStoreProvider.overrideWithValue(_MemoryStore()),
        fontPickerProvider.overrideWithValue(() async => queue.isEmpty ? null : queue.removeAt(0)),
      ]);
      addTearDown(container.dispose);
      await tester.binding.setSurfaceSize(const Size(420, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: Consumer(builder: (context, ref, _) {
          final family = ref.watch(fontSettingsProvider).fontFamily;
          return MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: buildAppTheme(Brightness.dark, fontFamily: family),
            home: const ThemeSettingsScreen(),
          );
        }),
      ));
      await tester.pumpAndSettle();
      return (container, files);
    }

    String? appFamily(WidgetTester tester) =>
        Theme.of(tester.element(find.text('默认'))).textTheme.bodyMedium!.fontFamily;
    Finder radioOf(String label) => find.descendant(
        of: find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first, matching: find.byType(Icon));

    testWidgets('默认 is chosen; importing adds a row drawn in the font, a duplicate says 该字体已存在', (tester) async {
      final bytes = otf();
      final id = idOf(bytes);
      final (container, _) = await pump(tester, picks: [
        (name: 'Comfortaa-Regular.otf', bytes: bytes),
        (name: 'Comfortaa-Regular.otf', bytes: bytes),
        (name: 'notes.ttf', bytes: Uint8List.fromList('not a font at all'.codeUnits)),
      ]);
      expect(find.text('字体'), findsOneWidget);
      expect(tester.widget<Icon>(radioOf('默认')).icon, Icons.radio_button_checked);
      expect(find.text('导入字体'), findsOneWidget);

      await tester.tap(find.text('导入字体'));
      await tester.pump();
      await tester.pump();
      expect(find.text('字体导入成功'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      final row = tester.widget<Text>(find.text('Comfortaa-Regular'));
      expect(row.style!.fontFamily, 'uzv_user_$id');
      expect(tester.widget<Icon>(radioOf('Comfortaa-Regular').first).icon, Icons.radio_button_unchecked);
      expect(container.read(fontSettingsProvider).selectedId, isNull);

      await tester.tap(find.text('导入字体'));
      await tester.pump();
      await tester.pump();
      expect(find.text('该字体已存在'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(find.text('导入字体'));
      await tester.pump();
      await tester.pump();
      expect(find.text('字体导入失败'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('notes'), findsNothing);
    });

    testWidgets('choosing a font changes the app\'s font; × asks, and deleting it goes back to 默认', (tester) async {
      final bytes = otf();
      final family = 'uzv_user_${idOf(bytes)}';
      final (container, files) = await pump(tester, picks: [(name: 'Comfortaa-Regular.otf', bytes: bytes)]);
      await tester.tap(find.text('导入字体'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(find.text('Comfortaa-Regular'));
      await tester.pumpAndSettle();
      expect(appFamily(tester), family);
      expect(tester.widget<Icon>(radioOf('默认')).icon, Icons.radio_button_unchecked);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.text('删除字体'), findsWidgets);
      expect(find.text('确定删除该字体吗？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('Comfortaa-Regular'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '删除'));
      await tester.pumpAndSettle();
      expect(find.text('Comfortaa-Regular'), findsNothing);
      expect(container.read(fontSettingsProvider).selectedId, isNull);
      expect(appFamily(tester), buildAppTheme(Brightness.dark).textTheme.bodyMedium!.fontFamily);
      expect(tester.widget<Icon>(radioOf('默认')).icon, Icons.radio_button_checked);
      expect(files.files, isEmpty);
    });
  });
}
