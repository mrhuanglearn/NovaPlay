import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/app_preferences.dart';
import '../app/theme.dart';
import '../core/app_version.dart';
import '../l10n/l10n.dart';
import 'app_reset.dart';
import 'app_shell.dart';
import 'lock_dialogs.dart';
import 'preference_screens.dart';
import 'widgets.dart';

/// `/settings`, the 设置 tab. Same groups, entries and order as the original (数据 / 偏好 / 工具 / 开发者).
class SettingsIndexScreen extends ConsumerWidget {
  const SettingsIndexScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final language = ref.watch(appPreferencesProvider.select((p) => p.language));
    final lockHash = ref.watch(appPreferencesProvider.select((p) => p.lockHash));
    SettingsTile tile(IconData icon, String title, String subtitle, String route) =>
        SettingsTile(icon: icon, title: title, subtitle: subtitle, onTap: () => context.push(route));
    return Scaffold(
      appBar: AppBar(title: Text(l.tabSettings)),
      body: ListView(padding: EdgeInsets.only(bottom: tabBottomInset(context)), children: [
        SettingsSection(title: l.settingsGroupData, children: [
          tile(Icons.subscriptions_outlined, l.settingsSubscriptions, l.settingsSubscriptionsSub, '/subscriptions'),
          tile(Icons.live_tv_rounded, l.settingsLive, l.settingsLiveSub, '/live/settings'),
          tile(Icons.subtitles_outlined, l.settingsDanmu, l.settingsDanmuSub, '/settings/danmu'),
          tile(Icons.dns_outlined, l.settingsMediaServer, l.settingsMediaServerSub, '/emby/accounts'),
          tile(Icons.movie_filter_outlined, l.settingsTmdb, l.settingsTmdbSub, '/settings/tmdb'),
          tile(Icons.cloud_sync_outlined, l.settingsWebdav, l.settingsWebdavSub, '/settings/webdav'),
          tile(Icons.archive_outlined, l.settingsBackup, l.settingsBackupSub, '/settings/backup'),
          SettingsTile(
              icon: Icons.cleaning_services_outlined,
              title: l.settingsCleanup,
              subtitle: l.settingsCleanupSub,
              onTap: () => showCleanupSheet(context)),
          SettingsTile(
            icon: Icons.restart_alt,
            title: l.settingsReset,
            subtitle: l.settingsResetSub,
            destructive: true,
            onTap: () => confirmAndResetApp(context, ref),
          ),
        ]),
        SettingsSection(title: l.settingsGroupPreferences, children: [
          tile(Icons.space_dashboard_outlined, l.settingsHomeTabs, l.settingsHomeTabsSub, '/settings/home-tabs'),
          tile(Icons.play_circle_outline, l.settingsPlayer, l.settingsPlayerSub, '/settings/player'),
          tile(Icons.language, l.language, languageLabel(l, language), '/settings/language'),
          tile(Icons.palette_outlined, l.settingsTheme, l.settingsThemeSub, '/settings/theme'),
          tile(Icons.tune, l.settingsFeatures, l.settingsFeaturesSub, '/settings/feature'),
          SettingsTile(
            icon: Icons.lock_outline,
            title: l.lockPassword,
            subtitle: lockStateLabel(l, lockHash),
            onTap: () => showLockPasswordDialog(context),
          ),
        ]),
        SettingsSection(title: l.settingsGroupTools, children: [
          tile(Icons.travel_explore, l.settingsSniffer, l.settingsSnifferSub, '/sniffer/web'),
        ]),
        SettingsSection(title: l.settingsGroupDeveloper, children: [
          tile(Icons.bug_report_outlined, l.settingsCatpawDebug, l.settingsCatpawDebugSub, '/debug'),
        ]),
        Padding(
          padding: const EdgeInsets.only(top: 22, bottom: 8),
          child: Text('${l.appName} v$appVersion',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: AppColors.of(context).subtitle)),
        ),
      ]),
    );
  }
}
