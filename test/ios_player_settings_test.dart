import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/app/theme.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/player/player_launcher.dart';
import 'package:uzv_reimpl/l10n/l10n.dart';
import 'package:uzv_reimpl/ui/player_settings_screens.dart';

void main() {
  late PlayerConfigRepository repo;

  setUp(() {
    repo = PlayerConfigRepository(store: _MemoryStore('player_config.json'));
  });

  Future<void> pumpIos(WidgetTester tester, {Key? screenKey}) async {
    await tester.binding.setSurfaceSize(const Size(500, 4000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final baseTheme = buildAppTheme(Brightness.light);
    await tester.pumpWidget(ProviderScope(
      overrides: [playerConfigRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: baseTheme.copyWith(platform: TargetPlatform.iOS),
        home: PlayerSettingsScreen(key: screenKey),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('iOS PlayerSettingsScreen exposes AVPlayer, MPV, and VLC kernels and hides Android fonts folder',
      (tester) async {
    await pumpIos(tester);

    expect(find.text('AVPlayer'), findsOneWidget);
    expect(find.textContaining('Apple VideoToolbox'), findsOneWidget);
    expect(find.text('进入后台自动画中画'), findsOneWidget);
    // Android-only /storage/emulated/0/Fonts directory row is hidden on iOS
    expect(find.text('字体目录（可选）'), findsNothing);

    await tester.tap(find.text('播放内核'));
    await tester.pumpAndSettle();
    expect(find.text('AVPlayer (SYSTEM)'), findsOneWidget);
    expect(find.text('MPV (MPV)'), findsOneWidget);
    expect(find.text('VLC (FFmpeg)'), findsOneWidget);
    expect(find.text('EXO (SYSTEM)'), findsNothing);
    expect(find.text('MDK (MDK)'), findsNothing);

    await tester.tap(find.text('MPV (MPV)'));
    await tester.pumpAndSettle();

    expect(find.text('MPV'), findsOneWidget);
    expect(find.textContaining('libmpv'), findsOneWidget);
    // Selecting MPV on iOS hides the PiP switch and force-disables autoPictureInPicture
    expect(find.text('进入后台自动画中画'), findsNothing);

    final (savedMpv, _) = await repo.load();
    expect(savedMpv.kernel, 'mpv');
    expect(savedMpv.autoPictureInPicture, isFalse);

    await tester.tap(find.text('播放内核'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('VLC (FFmpeg)'));
    await tester.pumpAndSettle();

    expect(find.text('VLC'), findsOneWidget);
    expect(find.textContaining('FFmpeg / libvlc'), findsOneWidget);
    expect(find.text('进入后台自动画中画'), findsOneWidget);
    expect(find.text('iOS 系统画中画仅在 AVPlayer 内核下可用'), findsOneWidget);

    final (savedVlc, _) = await repo.load();
    expect(savedVlc.kernel, 'vlc');
  });

  testWidgets('iOS normalizes Android WebDAV-synced kernels (mpv -> MPV, mdk -> VLC, exo -> AVPlayer)',
      (tester) async {
    final p1 = defaultPlaybackConfig()
      ..kernel = 'mpv'
      ..autoPictureInPicture = true;
    await repo.save(p1, defaultDanmakuConfig());
    await pumpIos(tester, screenKey: const ValueKey('k1'));
    expect(find.text('MPV'), findsOneWidget);
    expect(find.text('进入后台自动画中画'), findsNothing);
    final (loadedMpv, _) = await repo.load();
    expect(loadedMpv.autoPictureInPicture, isFalse);

    final p2 = defaultPlaybackConfig()..kernel = 'mdk';
    await repo.save(p2, defaultDanmakuConfig());
    await pumpIos(tester, screenKey: const ValueKey('k2'));
    expect(find.text('VLC'), findsOneWidget);

    final p3 = defaultPlaybackConfig()..kernel = 'exo';
    await repo.save(p3, defaultDanmakuConfig());
    await pumpIos(tester, screenKey: const ValueKey('k3'));
    expect(find.text('AVPlayer'), findsOneWidget);
  });
}

class _MemoryStore extends JsonStore {
  _MemoryStore(super.name);
  Object? _data;

  @override
  Future<T> read<T>(T fallback) async => (_data as T?) ?? fallback;

  @override
  Future<void> write(Object? json) async => _data = json;
}
