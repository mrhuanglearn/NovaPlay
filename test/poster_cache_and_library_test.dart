import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/features/library/watch_repository.dart';
import 'package:uzv_reimpl/l10n/app_localizations.dart';
import 'package:uzv_reimpl/models/vod.dart';
import 'package:uzv_reimpl/ui/library_screen.dart';

void main() {
  testWidgets('HistoryView builds rows lazily instead of mounting all 250 entries at once', (tester) async {
    final entries = List.generate(
      250,
      (i) => ProgressEntry(
        item: VodItem(id: 'id_$i', name: 'History Title $i', siteKey: 's1'),
        lineIndex: 0,
        episodeIndex: 0,
        episodeName: '第1集',
        positionSeconds: 10,
        durationSeconds: 100,
        updatedAt: 1000 - i,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          historyListProvider.overrideWith((ref) async => entries),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: Scaffold(body: HistoryView()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('History Title 0'), findsOneWidget);
    expect(find.text('History Title 249'), findsNothing,
        reason: 'off-screen rows far down a 250-item history list must not be eagerly built');
  });
}
