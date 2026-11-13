import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/app/theme.dart';
import 'package:uzv_reimpl/l10n/l10n.dart';
import 'package:uzv_reimpl/ui/detail_screen.dart';

// User report (2026-11-13): on the 视频详情 page (立即播放), when the network failed, tapping 「重新加载」 did nothing —
// no spinner, no refresh. Riverpod kept showing the old error while the provider refetched, and an offline request fails
// at once, so the page never changed. 「重新加载」 now asks again and shows the spinner while it does.

void main() {
  testWidgets('重新加载 on a failed detail page shows the spinner and asks the spider again', (tester) async {
    var requests = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        catpawRuntimeProvider.overrideWith((ref) async => null),
        homeSitesProvider.overrideWithValue(const []),
        tmdbProvider.overrideWith((ref) async => null),
        videoDetailProvider.overrideWith((ref, q) async {
          requests++;
          throw Exception('SocketException: Failed host lookup');
        }),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildAppTheme(Brightness.light),
        home: const DetailScreen(vodId: 'v1', siteKey: 'none'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(find.text('重新加载'), findsOneWidget);

    await tester.tap(find.text('重新加载'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // The request already failed again, but the page still shows it is working.
    expect(requests, 2);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('重新加载'), findsNothing);

    await tester.pump(DetailScreenRetry.minSpinner);
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('重新加载'), findsOneWidget);
  });
}
