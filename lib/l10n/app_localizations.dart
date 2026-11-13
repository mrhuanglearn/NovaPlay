import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh')
  ];

  /// No description provided for @appName.
  ///
  /// In en, this message translates to:
  /// **'NovaPlay'**
  String get appName;

  /// No description provided for @tabHome.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get tabHome;

  /// No description provided for @tabLive.
  ///
  /// In en, this message translates to:
  /// **'Live'**
  String get tabLive;

  /// No description provided for @tabCalendar.
  ///
  /// In en, this message translates to:
  /// **'Calendar'**
  String get tabCalendar;

  /// No description provided for @tabLibrary.
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get tabLibrary;

  /// No description provided for @tabSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get tabSettings;

  /// No description provided for @pressBackAgainToExit.
  ///
  /// In en, this message translates to:
  /// **'Press back again to exit'**
  String get pressBackAgainToExit;

  /// No description provided for @loadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load'**
  String get loadFailed;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @paste.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get paste;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// No description provided for @add.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get add;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @search.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get search;

  /// No description provided for @all.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get all;

  /// No description provided for @goToSettings.
  ///
  /// In en, this message translates to:
  /// **'Go to settings'**
  String get goToSettings;

  /// No description provided for @noData.
  ///
  /// In en, this message translates to:
  /// **'No data'**
  String get noData;

  /// No description provided for @nothingHere.
  ///
  /// In en, this message translates to:
  /// **'Nothing here yet'**
  String get nothingHere;

  /// No description provided for @settingsGroupData.
  ///
  /// In en, this message translates to:
  /// **'Data'**
  String get settingsGroupData;

  /// No description provided for @settingsGroupPreferences.
  ///
  /// In en, this message translates to:
  /// **'Preferences'**
  String get settingsGroupPreferences;

  /// No description provided for @settingsGroupTools.
  ///
  /// In en, this message translates to:
  /// **'Tools'**
  String get settingsGroupTools;

  /// No description provided for @settingsSubscriptions.
  ///
  /// In en, this message translates to:
  /// **'Subscriptions'**
  String get settingsSubscriptions;

  /// No description provided for @settingsSubscriptionsSub.
  ///
  /// In en, this message translates to:
  /// **'Manage sources and auto-update'**
  String get settingsSubscriptionsSub;

  /// No description provided for @settingsLive.
  ///
  /// In en, this message translates to:
  /// **'Live'**
  String get settingsLive;

  /// No description provided for @settingsLiveSub.
  ///
  /// In en, this message translates to:
  /// **'Live sources, global EPG and hidden categories'**
  String get settingsLiveSub;

  /// No description provided for @settingsDanmu.
  ///
  /// In en, this message translates to:
  /// **'Danmaku service'**
  String get settingsDanmu;

  /// No description provided for @settingsDanmuSub.
  ///
  /// In en, this message translates to:
  /// **'Danmaku API address and access token'**
  String get settingsDanmuSub;

  /// No description provided for @settingsMediaServer.
  ///
  /// In en, this message translates to:
  /// **'Media servers'**
  String get settingsMediaServer;

  /// No description provided for @settingsMediaServerSub.
  ///
  /// In en, this message translates to:
  /// **'Emby and Jellyfin accounts, browse libraries'**
  String get settingsMediaServerSub;

  /// No description provided for @settingsTmdb.
  ///
  /// In en, this message translates to:
  /// **'TMDB'**
  String get settingsTmdb;

  /// No description provided for @settingsTmdbSub.
  ///
  /// In en, this message translates to:
  /// **'API key and scraping proxy'**
  String get settingsTmdbSub;

  /// No description provided for @settingsWebdav.
  ///
  /// In en, this message translates to:
  /// **'WebDAV sync'**
  String get settingsWebdav;

  /// No description provided for @settingsWebdavSub.
  ///
  /// In en, this message translates to:
  /// **'Sync data across devices (choose what to sync)'**
  String get settingsWebdavSub;

  /// No description provided for @settingsBackup.
  ///
  /// In en, this message translates to:
  /// **'Backup & restore'**
  String get settingsBackup;

  /// No description provided for @settingsBackupSub.
  ///
  /// In en, this message translates to:
  /// **'Pack data as a zip backup or share it; restore from a backup'**
  String get settingsBackupSub;

  /// No description provided for @settingsPlayer.
  ///
  /// In en, this message translates to:
  /// **'Player'**
  String get settingsPlayer;

  /// No description provided for @settingsPlayerSub.
  ///
  /// In en, this message translates to:
  /// **'Kernel, speed, subtitles and display'**
  String get settingsPlayerSub;

  /// No description provided for @settingsSniffer.
  ///
  /// In en, this message translates to:
  /// **'Web video sniffer'**
  String get settingsSniffer;

  /// No description provided for @settingsSnifferSub.
  ///
  /// In en, this message translates to:
  /// **'Find videos and streams in web pages'**
  String get settingsSnifferSub;

  /// No description provided for @secondsShort.
  ///
  /// In en, this message translates to:
  /// **'s'**
  String get secondsShort;

  /// No description provided for @saved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get saved;

  /// No description provided for @serverAddress.
  ///
  /// In en, this message translates to:
  /// **'Server address'**
  String get serverAddress;

  /// No description provided for @port.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get port;

  /// No description provided for @tokenOptional.
  ///
  /// In en, this message translates to:
  /// **'Token (optional)'**
  String get tokenOptional;

  /// No description provided for @testConnection.
  ///
  /// In en, this message translates to:
  /// **'Test connection'**
  String get testConnection;

  /// No description provided for @playerGroupPlayback.
  ///
  /// In en, this message translates to:
  /// **'Playback'**
  String get playerGroupPlayback;

  /// No description provided for @playerKernel.
  ///
  /// In en, this message translates to:
  /// **'Player kernel'**
  String get playerKernel;

  /// No description provided for @playerHwDecode.
  ///
  /// In en, this message translates to:
  /// **'Hardware acceleration'**
  String get playerHwDecode;

  /// No description provided for @playerFit.
  ///
  /// In en, this message translates to:
  /// **'Picture fill'**
  String get playerFit;

  /// No description provided for @playerFitFit.
  ///
  /// In en, this message translates to:
  /// **'Original ratio'**
  String get playerFitFit;

  /// No description provided for @playerFitFill.
  ///
  /// In en, this message translates to:
  /// **'Stretch to fill'**
  String get playerFitFill;

  /// No description provided for @playerFitZoom.
  ///
  /// In en, this message translates to:
  /// **'Crop to fill'**
  String get playerFitZoom;

  /// No description provided for @playerDefaultSpeed.
  ///
  /// In en, this message translates to:
  /// **'Default speed'**
  String get playerDefaultSpeed;

  /// No description provided for @playerLongPressSpeed.
  ///
  /// In en, this message translates to:
  /// **'Long-press speed'**
  String get playerLongPressSpeed;

  /// No description provided for @playerDoubleTapSeek.
  ///
  /// In en, this message translates to:
  /// **'Seek step (seconds)'**
  String get playerDoubleTapSeek;

  /// No description provided for @playerMpvNote.
  ///
  /// In en, this message translates to:
  /// **'MPV needs libmpv.so in the APK. Without it the player page falls back to Exo and says why.'**
  String get playerMpvNote;

  /// No description provided for @playerGroupSubtitles.
  ///
  /// In en, this message translates to:
  /// **'Subtitles & audio'**
  String get playerGroupSubtitles;

  /// No description provided for @playerSubtitleLang.
  ///
  /// In en, this message translates to:
  /// **'Preferred subtitle language'**
  String get playerSubtitleLang;

  /// No description provided for @playerSubtitleFont.
  ///
  /// In en, this message translates to:
  /// **'Subtitle font'**
  String get playerSubtitleFont;

  /// No description provided for @playerSubtitleFontHint.
  ///
  /// In en, this message translates to:
  /// **'A system font name, or a file name in the fonts folder'**
  String get playerSubtitleFontHint;

  /// No description provided for @playerFontsDir.
  ///
  /// In en, this message translates to:
  /// **'Fonts folder (optional)'**
  String get playerFontsDir;

  /// No description provided for @playerAudioLang.
  ///
  /// In en, this message translates to:
  /// **'Preferred audio language'**
  String get playerAudioLang;

  /// No description provided for @playerSubtitleNote.
  ///
  /// In en, this message translates to:
  /// **'SRT, WebVTT, TTML and basic ASS/SSA are supported. ASS is drawn by Exo\'s simple parser, not libass.'**
  String get playerSubtitleNote;

  /// No description provided for @playerGroupBehaviour.
  ///
  /// In en, this message translates to:
  /// **'Behaviour'**
  String get playerGroupBehaviour;

  /// No description provided for @playerPreferLandscape.
  ///
  /// In en, this message translates to:
  /// **'Prefer landscape'**
  String get playerPreferLandscape;

  /// No description provided for @playerAutoPip.
  ///
  /// In en, this message translates to:
  /// **'Picture-in-picture in background'**
  String get playerAutoPip;

  /// No description provided for @playerPauseInBackground.
  ///
  /// In en, this message translates to:
  /// **'Pause in background'**
  String get playerPauseInBackground;

  /// No description provided for @playerSkipNotice.
  ///
  /// In en, this message translates to:
  /// **'Skip notice'**
  String get playerSkipNotice;

  /// No description provided for @playerEpisodeSwitchNotice.
  ///
  /// In en, this message translates to:
  /// **'Episode switch notice'**
  String get playerEpisodeSwitchNotice;

  /// No description provided for @playerHaptics.
  ///
  /// In en, this message translates to:
  /// **'Haptic feedback'**
  String get playerHaptics;

  /// No description provided for @playerGroupOverlay.
  ///
  /// In en, this message translates to:
  /// **'On-screen info'**
  String get playerGroupOverlay;

  /// No description provided for @playerShowNetSpeed.
  ///
  /// In en, this message translates to:
  /// **'Always show network speed'**
  String get playerShowNetSpeed;

  /// No description provided for @playerShowStats.
  ///
  /// In en, this message translates to:
  /// **'Show frame rate and codec'**
  String get playerShowStats;

  /// No description provided for @playerShowTotalDuration.
  ///
  /// In en, this message translates to:
  /// **'Show total duration on the progress bar'**
  String get playerShowTotalDuration;

  /// No description provided for @playerHideSeekButtons.
  ///
  /// In en, this message translates to:
  /// **'Hide centre seek buttons'**
  String get playerHideSeekButtons;

  /// No description provided for @danmuEnable.
  ///
  /// In en, this message translates to:
  /// **'Enable danmaku'**
  String get danmuEnable;

  /// No description provided for @danmuSource.
  ///
  /// In en, this message translates to:
  /// **'Danmaku service source'**
  String get danmuSource;

  /// No description provided for @danmuModeOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get danmuModeOff;

  /// No description provided for @danmuModeBuiltin.
  ///
  /// In en, this message translates to:
  /// **'Local'**
  String get danmuModeBuiltin;

  /// No description provided for @danmuModeSubscription.
  ///
  /// In en, this message translates to:
  /// **'Subscription'**
  String get danmuModeSubscription;

  /// No description provided for @danmuModeRemote.
  ///
  /// In en, this message translates to:
  /// **'Remote'**
  String get danmuModeRemote;

  /// No description provided for @danmuModeOffNote.
  ///
  /// In en, this message translates to:
  /// **'No danmaku server is used.'**
  String get danmuModeOffNote;

  /// No description provided for @danmuModeBuiltinNote.
  ///
  /// In en, this message translates to:
  /// **'Runs a danmu_api script you supply inside the Node runtime.'**
  String get danmuModeBuiltinNote;

  /// No description provided for @danmuModeSubscriptionNote.
  ///
  /// In en, this message translates to:
  /// **'Uses port 9321 of the active subscription.'**
  String get danmuModeSubscriptionNote;

  /// No description provided for @danmuModeRemoteNote.
  ///
  /// In en, this message translates to:
  /// **'Your own danmu_api server.'**
  String get danmuModeRemoteNote;

  /// No description provided for @danmuScriptUrl.
  ///
  /// In en, this message translates to:
  /// **'danmu_api script URL (server.cjs)'**
  String get danmuScriptUrl;

  /// No description provided for @danmuDownloadScript.
  ///
  /// In en, this message translates to:
  /// **'Download / update script'**
  String get danmuDownloadScript;

  /// No description provided for @danmuScriptDownloaded.
  ///
  /// In en, this message translates to:
  /// **'Script downloaded (md5 {md5})'**
  String danmuScriptDownloaded(String md5);

  /// No description provided for @danmuNotReachable.
  ///
  /// In en, this message translates to:
  /// **'Not reachable or not configured'**
  String get danmuNotReachable;

  /// No description provided for @danmuReachable.
  ///
  /// In en, this message translates to:
  /// **'Reachable ({count} results for \"a\")'**
  String danmuReachable(int count);

  /// No description provided for @danmuGroupAppearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get danmuGroupAppearance;

  /// No description provided for @danmuOpacity.
  ///
  /// In en, this message translates to:
  /// **'Opacity'**
  String get danmuOpacity;

  /// No description provided for @danmuFontSize.
  ///
  /// In en, this message translates to:
  /// **'Font size'**
  String get danmuFontSize;

  /// No description provided for @danmuScrollSpeed.
  ///
  /// In en, this message translates to:
  /// **'Scroll speed'**
  String get danmuScrollSpeed;

  /// No description provided for @danmuArea.
  ///
  /// In en, this message translates to:
  /// **'Display area'**
  String get danmuArea;

  /// No description provided for @danmuDelay.
  ///
  /// In en, this message translates to:
  /// **'Delay'**
  String get danmuDelay;

  /// No description provided for @danmuTop.
  ///
  /// In en, this message translates to:
  /// **'Top comments'**
  String get danmuTop;

  /// No description provided for @danmuBottom.
  ///
  /// In en, this message translates to:
  /// **'Bottom comments'**
  String get danmuBottom;

  /// No description provided for @danmuBlockedWords.
  ///
  /// In en, this message translates to:
  /// **'Blocked words'**
  String get danmuBlockedWords;

  /// No description provided for @danmuBlockedWordsHint.
  ///
  /// In en, this message translates to:
  /// **'One per line'**
  String get danmuBlockedWordsHint;

  /// No description provided for @connectionOk.
  ///
  /// In en, this message translates to:
  /// **'Connection OK'**
  String get connectionOk;

  /// No description provided for @advanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get advanced;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// No description provided for @restore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get restore;

  /// No description provided for @copied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get copied;

  /// No description provided for @clipboardEmpty.
  ///
  /// In en, this message translates to:
  /// **'Clipboard is empty'**
  String get clipboardEmpty;

  /// No description provided for @tmdbConnectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed (check key / address)'**
  String get tmdbConnectionFailed;

  /// No description provided for @tmdbConnectTitle.
  ///
  /// In en, this message translates to:
  /// **'Connect TMDB'**
  String get tmdbConnectTitle;

  /// No description provided for @tmdbConnectDescription.
  ///
  /// In en, this message translates to:
  /// **'Once connected, posters, overviews and cast are matched automatically and the calendar stays up to date'**
  String get tmdbConnectDescription;

  /// No description provided for @tmdbEnable.
  ///
  /// In en, this message translates to:
  /// **'Enable TMDB'**
  String get tmdbEnable;

  /// No description provided for @tmdbEnableSub.
  ///
  /// In en, this message translates to:
  /// **'Posters, episode names and the tracking calendar'**
  String get tmdbEnableSub;

  /// No description provided for @tmdbKeyHint.
  ///
  /// In en, this message translates to:
  /// **'TMDB API key (v3) or read access token (v4), detected automatically'**
  String get tmdbKeyHint;

  /// No description provided for @tmdbApiBase.
  ///
  /// In en, this message translates to:
  /// **'API address (empty = official)'**
  String get tmdbApiBase;

  /// No description provided for @tmdbImageBase.
  ///
  /// In en, this message translates to:
  /// **'Image address (empty = official)'**
  String get tmdbImageBase;

  /// No description provided for @tmdbMatchWait.
  ///
  /// In en, this message translates to:
  /// **'Detail page match wait (seconds)'**
  String get tmdbMatchWait;

  /// No description provided for @tmdbKeyStorageNote.
  ///
  /// In en, this message translates to:
  /// **'The key is stored in plain text in tmdb_settings.json and is included in WebDAV sync and backups.'**
  String get tmdbKeyStorageNote;

  /// No description provided for @webdavAccount.
  ///
  /// In en, this message translates to:
  /// **'Account name'**
  String get webdavAccount;

  /// No description provided for @webdavSubFolder.
  ///
  /// In en, this message translates to:
  /// **'Sub folder (optional)'**
  String get webdavSubFolder;

  /// No description provided for @webdavSubFolderHint.
  ///
  /// In en, this message translates to:
  /// **'Isolates data when sharing one WebDAV; leave empty to use the root'**
  String get webdavSubFolderHint;

  /// No description provided for @webdavSyncNow.
  ///
  /// In en, this message translates to:
  /// **'Sync now'**
  String get webdavSyncNow;

  /// No description provided for @webdavSyncResult.
  ///
  /// In en, this message translates to:
  /// **'Uploaded {pushed}, downloaded {pulled} document(s)'**
  String webdavSyncResult(int pushed, int pulled);

  /// No description provided for @webdavNote.
  ///
  /// In en, this message translates to:
  /// **'Favorites, history, progress, TMDB matches and key, tracking, player and live settings are synced. The password and the TMDB key are stored in plain text.'**
  String get webdavNote;

  /// No description provided for @webdavNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'Configure WebDAV first'**
  String get webdavNotConfigured;

  /// No description provided for @backupGroupExport.
  ///
  /// In en, this message translates to:
  /// **'Export backup'**
  String get backupGroupExport;

  /// No description provided for @backupGroupRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore from backup'**
  String get backupGroupRestore;

  /// No description provided for @backupShareFile.
  ///
  /// In en, this message translates to:
  /// **'Share backup file'**
  String get backupShareFile;

  /// No description provided for @backupShareFileSub.
  ///
  /// In en, this message translates to:
  /// **'One JSON file with every synced document'**
  String get backupShareFileSub;

  /// No description provided for @backupShareText.
  ///
  /// In en, this message translates to:
  /// **'NovaPlay backup'**
  String get backupShareText;

  /// No description provided for @backupCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy backup to clipboard'**
  String get backupCopy;

  /// No description provided for @backupRestoreClipboard.
  ///
  /// In en, this message translates to:
  /// **'Restore from clipboard'**
  String get backupRestoreClipboard;

  /// No description provided for @backupRestoreWebdav.
  ///
  /// In en, this message translates to:
  /// **'Restore from WebDAV'**
  String get backupRestoreWebdav;

  /// No description provided for @backupRestoreWebdavSub.
  ///
  /// In en, this message translates to:
  /// **'Takes the remote copy of every document'**
  String get backupRestoreWebdavSub;

  /// No description provided for @backupRestored.
  ///
  /// In en, this message translates to:
  /// **'Restored {count} document(s)'**
  String backupRestored(int count);

  /// No description provided for @backupSensitiveNote.
  ///
  /// In en, this message translates to:
  /// **'Backups may contain accounts, passwords and keys; be careful when sharing them.'**
  String get backupSensitiveNote;

  /// No description provided for @name.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get name;

  /// No description provided for @subscriptions.
  ///
  /// In en, this message translates to:
  /// **'Subscriptions'**
  String get subscriptions;

  /// No description provided for @subscriptionAdd.
  ///
  /// In en, this message translates to:
  /// **'Add subscription'**
  String get subscriptionAdd;

  /// No description provided for @subscriptionsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No subscriptions yet'**
  String get subscriptionsEmptyTitle;

  /// No description provided for @subscriptionsEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Add a subscription to start aggregating your content'**
  String get subscriptionsEmptySubtitle;

  /// No description provided for @subscriptionDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete subscription'**
  String get subscriptionDelete;

  /// No description provided for @subscriptionDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"?'**
  String subscriptionDeleteConfirm(String name);

  /// No description provided for @subscriptionKindNetwork.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get subscriptionKindNetwork;

  /// No description provided for @subscriptionKindCloud.
  ///
  /// In en, this message translates to:
  /// **'Cloud'**
  String get subscriptionKindCloud;

  /// No description provided for @subscriptionNetworkHint.
  ///
  /// In en, this message translates to:
  /// **'Add a data source to aggregate content'**
  String get subscriptionNetworkHint;

  /// No description provided for @subscriptionCloudHint.
  ///
  /// In en, this message translates to:
  /// **'Connect directly to a catpaw service running elsewhere, no script download'**
  String get subscriptionCloudHint;

  /// No description provided for @subscriptionSourceUrl.
  ///
  /// In en, this message translates to:
  /// **'Data source URL'**
  String get subscriptionSourceUrl;

  /// No description provided for @subscriptionCloudAddress.
  ///
  /// In en, this message translates to:
  /// **'Cloud service address'**
  String get subscriptionCloudAddress;

  /// No description provided for @subscriptionNameHint.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to derive it from the address'**
  String get subscriptionNameHint;

  /// No description provided for @subscriptionDanmuToken.
  ///
  /// In en, this message translates to:
  /// **'Danmaku service token (optional)'**
  String get subscriptionDanmuToken;

  /// No description provided for @subscriptionDanmuTokenHint.
  ///
  /// In en, this message translates to:
  /// **'Path prefix of the subscription\'s own danmaku server'**
  String get subscriptionDanmuTokenHint;

  /// No description provided for @subscriptionLock.
  ///
  /// In en, this message translates to:
  /// **'Lock'**
  String get subscriptionLock;

  /// No description provided for @subscriptionLockSub.
  ///
  /// In en, this message translates to:
  /// **'Locked subscriptions are visible only after the lock password is verified'**
  String get subscriptionLockSub;

  /// No description provided for @subscriptionUrlRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter the data source URL'**
  String get subscriptionUrlRequired;

  /// No description provided for @filter.
  ///
  /// In en, this message translates to:
  /// **'Filter'**
  String get filter;

  /// No description provided for @homeCatpawUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Cannot connect to the catpaw service'**
  String get homeCatpawUnavailable;

  /// No description provided for @libraryHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get libraryHistory;

  /// No description provided for @libraryFavorites.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get libraryFavorites;

  /// No description provided for @libraryDownloads.
  ///
  /// In en, this message translates to:
  /// **'Downloads'**
  String get libraryDownloads;

  /// No description provided for @historyEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Nothing watched yet, go find something to watch'**
  String get historyEmptySubtitle;

  /// No description provided for @favoritesEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No favorites yet'**
  String get favoritesEmptyTitle;

  /// No description provided for @favoritesEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Find videos you like and favorite them'**
  String get favoritesEmptySubtitle;

  /// No description provided for @downloadsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No downloads'**
  String get downloadsEmptyTitle;

  /// No description provided for @downloadsEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'No download tasks'**
  String get downloadsEmptySubtitle;

  /// No description provided for @downloadsOtherGroup.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get downloadsOtherGroup;

  /// No description provided for @downloadsDoneCount.
  ///
  /// In en, this message translates to:
  /// **'{done}/{total} done'**
  String downloadsDoneCount(int done, int total);

  /// No description provided for @downloadQueued.
  ///
  /// In en, this message translates to:
  /// **'Queued'**
  String get downloadQueued;

  /// No description provided for @downloadRunning.
  ///
  /// In en, this message translates to:
  /// **'Downloading'**
  String get downloadRunning;

  /// No description provided for @downloadPaused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get downloadPaused;

  /// No description provided for @downloadDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get downloadDone;

  /// No description provided for @downloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get downloadFailed;

  /// No description provided for @downloadPause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get downloadPause;

  /// No description provided for @downloadResume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get downloadResume;

  /// No description provided for @noResults.
  ///
  /// In en, this message translates to:
  /// **'No results'**
  String get noResults;

  /// No description provided for @mediaSeries.
  ///
  /// In en, this message translates to:
  /// **'Series'**
  String get mediaSeries;

  /// No description provided for @mediaMovie.
  ///
  /// In en, this message translates to:
  /// **'Movie'**
  String get mediaMovie;

  /// No description provided for @tmdbNotEnabledError.
  ///
  /// In en, this message translates to:
  /// **'Enable TMDB and enter an API key in Settings first'**
  String get tmdbNotEnabledError;

  /// No description provided for @tmdbSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search TMDB'**
  String get tmdbSearchHint;

  /// No description provided for @tmdbSearchPrompt.
  ///
  /// In en, this message translates to:
  /// **'Type a title and press search'**
  String get tmdbSearchPrompt;

  /// No description provided for @trackingSeason.
  ///
  /// In en, this message translates to:
  /// **'Season'**
  String get trackingSeason;

  /// No description provided for @trackingSeasonNumber.
  ///
  /// In en, this message translates to:
  /// **'Season number'**
  String get trackingSeasonNumber;

  /// No description provided for @trackingManage.
  ///
  /// In en, this message translates to:
  /// **'Tracking'**
  String get trackingManage;

  /// No description provided for @trackingAdd.
  ///
  /// In en, this message translates to:
  /// **'Add series'**
  String get trackingAdd;

  /// No description provided for @trackingAutoSync.
  ///
  /// In en, this message translates to:
  /// **'Sync favorites to the calendar'**
  String get trackingAutoSync;

  /// No description provided for @trackingAutoSyncSub.
  ///
  /// In en, this message translates to:
  /// **'Favorited series that TMDB knows join the calendar'**
  String get trackingAutoSyncSub;

  /// No description provided for @trackingEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing tracked yet'**
  String get trackingEmpty;

  /// No description provided for @trackingFollowed.
  ///
  /// In en, this message translates to:
  /// **'Following'**
  String get trackingFollowed;

  /// No description provided for @trackingShowSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Season {season} · watched {watched}'**
  String trackingShowSubtitle(int season, int watched);

  /// No description provided for @calendarTmdbDisabled.
  ///
  /// In en, this message translates to:
  /// **'TMDB is off, so the calendar cannot be updated'**
  String get calendarTmdbDisabled;

  /// No description provided for @calendarThisWeek.
  ///
  /// In en, this message translates to:
  /// **'This week'**
  String get calendarThisWeek;

  /// No description provided for @calendarNothingThisWeek.
  ///
  /// In en, this message translates to:
  /// **'Nothing airs this week'**
  String get calendarNothingThisWeek;

  /// No description provided for @calendarEpisode.
  ///
  /// In en, this message translates to:
  /// **'E{number} {name}'**
  String calendarEpisode(int number, String name);

  /// No description provided for @markedWatched.
  ///
  /// In en, this message translates to:
  /// **'Marked watched'**
  String get markedWatched;

  /// No description provided for @markedUnwatched.
  ///
  /// In en, this message translates to:
  /// **'Marked unwatched'**
  String get markedUnwatched;

  /// No description provided for @liveSearchChannels.
  ///
  /// In en, this message translates to:
  /// **'Search channels'**
  String get liveSearchChannels;

  /// No description provided for @liveSettings.
  ///
  /// In en, this message translates to:
  /// **'Live settings'**
  String get liveSettings;

  /// No description provided for @liveEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No live sources yet'**
  String get liveEmptyTitle;

  /// No description provided for @liveEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Add an M3U playlist to start watching'**
  String get liveEmptySubtitle;

  /// No description provided for @liveAddSource.
  ///
  /// In en, this message translates to:
  /// **'Add live source'**
  String get liveAddSource;

  /// No description provided for @liveEditSource.
  ///
  /// In en, this message translates to:
  /// **'Edit live source'**
  String get liveEditSource;

  /// No description provided for @liveNoChannels.
  ///
  /// In en, this message translates to:
  /// **'No channels'**
  String get liveNoChannels;

  /// No description provided for @liveSourcesGroup.
  ///
  /// In en, this message translates to:
  /// **'Live sources'**
  String get liveSourcesGroup;

  /// No description provided for @liveBlockedGroup.
  ///
  /// In en, this message translates to:
  /// **'Blocked categories'**
  String get liveBlockedGroup;

  /// No description provided for @liveBlockedCategories.
  ///
  /// In en, this message translates to:
  /// **'Blocked categories'**
  String get liveBlockedCategories;

  /// No description provided for @liveBlockedCategoriesSub.
  ///
  /// In en, this message translates to:
  /// **'Channels of a blocked category are hidden'**
  String get liveBlockedCategoriesSub;

  /// No description provided for @liveM3uUrl.
  ///
  /// In en, this message translates to:
  /// **'M3U address'**
  String get liveM3uUrl;

  /// No description provided for @liveEpgUrl.
  ///
  /// In en, this message translates to:
  /// **'XMLTV guide address (optional)'**
  String get liveEpgUrl;

  /// No description provided for @favorite.
  ///
  /// In en, this message translates to:
  /// **'Favorite'**
  String get favorite;

  /// No description provided for @notFound.
  ///
  /// In en, this message translates to:
  /// **'Not found'**
  String get notFound;

  /// No description provided for @downloadStarted.
  ///
  /// In en, this message translates to:
  /// **'Download started'**
  String get downloadStarted;

  /// No description provided for @addedToCalendar.
  ///
  /// In en, this message translates to:
  /// **'Added to the tracking calendar'**
  String get addedToCalendar;

  /// No description provided for @detailDirector.
  ///
  /// In en, this message translates to:
  /// **'Director: {name}'**
  String detailDirector(String name);

  /// No description provided for @detailCast.
  ///
  /// In en, this message translates to:
  /// **'Cast: {names}'**
  String detailCast(String names);

  /// No description provided for @detailMatchTmdb.
  ///
  /// In en, this message translates to:
  /// **'Match TMDB'**
  String get detailMatchTmdb;

  /// No description provided for @detailNoLines.
  ///
  /// In en, this message translates to:
  /// **'No playable lines'**
  String get detailNoLines;

  /// No description provided for @detailLongPressToDownload.
  ///
  /// In en, this message translates to:
  /// **'Long-press an episode to download it.'**
  String get detailLongPressToDownload;

  /// No description provided for @searchHint.
  ///
  /// In en, this message translates to:
  /// **'Search videos…'**
  String get searchHint;

  /// No description provided for @searchPrompt.
  ///
  /// In en, this message translates to:
  /// **'Type a keyword to search every site at once'**
  String get searchPrompt;

  /// No description provided for @userName.
  ///
  /// In en, this message translates to:
  /// **'User name'**
  String get userName;

  /// No description provided for @signIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get signIn;

  /// No description provided for @signInFailed.
  ///
  /// In en, this message translates to:
  /// **'Sign-in failed: {error}'**
  String signInFailed(String error);

  /// No description provided for @play.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get play;

  /// No description provided for @embyAddServer.
  ///
  /// In en, this message translates to:
  /// **'Add server'**
  String get embyAddServer;

  /// No description provided for @embyServerType.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get embyServerType;

  /// No description provided for @embyEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No servers yet'**
  String get embyEmptyTitle;

  /// No description provided for @embySearchLibrary.
  ///
  /// In en, this message translates to:
  /// **'Search library'**
  String get embySearchLibrary;

  /// No description provided for @embyAccountNotFound.
  ///
  /// In en, this message translates to:
  /// **'Account not found'**
  String get embyAccountNotFound;

  /// No description provided for @embyContinueWatching.
  ///
  /// In en, this message translates to:
  /// **'Continue watching'**
  String get embyContinueWatching;

  /// No description provided for @embyLatest.
  ///
  /// In en, this message translates to:
  /// **'Latest'**
  String get embyLatest;

  /// No description provided for @embySeason.
  ///
  /// In en, this message translates to:
  /// **'Season {season}'**
  String embySeason(int season);

  /// No description provided for @embyInProgress.
  ///
  /// In en, this message translates to:
  /// **'In progress'**
  String get embyInProgress;

  /// No description provided for @snifferNothingYet.
  ///
  /// In en, this message translates to:
  /// **'Nothing sniffed yet. Start playing a video on the page.'**
  String get snifferNothingYet;

  /// No description provided for @snifferPrompt.
  ///
  /// In en, this message translates to:
  /// **'Enter a page address to look for videos'**
  String get snifferPrompt;

  /// No description provided for @webAddressHint.
  ///
  /// In en, this message translates to:
  /// **'Address'**
  String get webAddressHint;

  /// No description provided for @configChecksumMismatchTitle.
  ///
  /// In en, this message translates to:
  /// **'Config checksum mismatch'**
  String get configChecksumMismatchTitle;

  /// No description provided for @configChecksumMismatchBody.
  ///
  /// In en, this message translates to:
  /// **'The md5 of index.config.js does not match its checksum file (the author may not have updated the .md5). Use this config anyway?'**
  String get configChecksumMismatchBody;

  /// No description provided for @done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// No description provided for @selectAll.
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get selectAll;

  /// No description provided for @deselectAll.
  ///
  /// In en, this message translates to:
  /// **'Deselect all'**
  String get deselectAll;

  /// No description provided for @selectedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String selectedCount(int count);

  /// No description provided for @subscriptionKindLocal.
  ///
  /// In en, this message translates to:
  /// **'Local'**
  String get subscriptionKindLocal;

  /// No description provided for @subscriptionLocalHint.
  ///
  /// In en, this message translates to:
  /// **'Pick a local zip archive as the subscription source. It must contain both index.js and index.config.js.'**
  String get subscriptionLocalHint;

  /// No description provided for @subscriptionLocalArchive.
  ///
  /// In en, this message translates to:
  /// **'Local archive'**
  String get subscriptionLocalArchive;

  /// No description provided for @subscriptionPickArchive.
  ///
  /// In en, this message translates to:
  /// **'Choose archive'**
  String get subscriptionPickArchive;

  /// No description provided for @subscriptionChipNetwork.
  ///
  /// In en, this message translates to:
  /// **'URL'**
  String get subscriptionChipNetwork;

  /// No description provided for @subscriptionChipCloud.
  ///
  /// In en, this message translates to:
  /// **'Cloud service'**
  String get subscriptionChipCloud;

  /// No description provided for @subscriptionChipLocal.
  ///
  /// In en, this message translates to:
  /// **'Local zip'**
  String get subscriptionChipLocal;

  /// No description provided for @subscriptionAutoUpdate.
  ///
  /// In en, this message translates to:
  /// **'Auto update'**
  String get subscriptionAutoUpdate;

  /// No description provided for @subscriptionAutoUpdateSub.
  ///
  /// In en, this message translates to:
  /// **'Sync the latest content on launch'**
  String get subscriptionAutoUpdateSub;

  /// No description provided for @subscriptionLockSingle.
  ///
  /// In en, this message translates to:
  /// **'Locking needs more than one subscription'**
  String get subscriptionLockSingle;

  /// No description provided for @subscriptionInstallUntrusted.
  ///
  /// In en, this message translates to:
  /// **'Install untrusted subscription'**
  String get subscriptionInstallUntrusted;

  /// No description provided for @subscriptionConnectCloud.
  ///
  /// In en, this message translates to:
  /// **'Connect cloud service'**
  String get subscriptionConnectCloud;

  /// No description provided for @subscriptionCantAdd.
  ///
  /// In en, this message translates to:
  /// **'Can\'t add?'**
  String get subscriptionCantAdd;

  /// No description provided for @notice.
  ///
  /// In en, this message translates to:
  /// **'Notice'**
  String get notice;

  /// No description provided for @subscriptionCantAddHelp.
  ///
  /// In en, this message translates to:
  /// **'Network environments differ. If you can\'t connect or the download fails, try [turn on your proxy with the proxy tool\'s TUN mode] or [turn the proxy off], then try again.'**
  String get subscriptionCantAddHelp;

  /// No description provided for @added.
  ///
  /// In en, this message translates to:
  /// **'Added'**
  String get added;

  /// No description provided for @subscriptionDuplicate.
  ///
  /// In en, this message translates to:
  /// **'A subscription with this URL already exists'**
  String get subscriptionDuplicate;

  /// No description provided for @subscriptionDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to download the subscription: {error}'**
  String subscriptionDownloadFailed(String error);

  /// No description provided for @subscriptionZipFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to install the local archive: {error}'**
  String subscriptionZipFailed(String error);

  /// No description provided for @subscriptionZipRequired.
  ///
  /// In en, this message translates to:
  /// **'Choose a zip archive first'**
  String get subscriptionZipRequired;

  /// No description provided for @subscriptionLastUpdated.
  ///
  /// In en, this message translates to:
  /// **'Last updated'**
  String get subscriptionLastUpdated;

  /// No description provided for @subscriptionLastUpdatedAt.
  ///
  /// In en, this message translates to:
  /// **'Updated {when}'**
  String subscriptionLastUpdatedAt(String when);

  /// No description provided for @timeJustNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get timeJustNow;

  /// No description provided for @timeMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{n} min ago'**
  String timeMinutesAgo(int n);

  /// No description provided for @timeHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{n} h ago'**
  String timeHoursAgo(int n);

  /// No description provided for @timeDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'{n} d ago'**
  String timeDaysAgo(int n);

  /// No description provided for @subscriptionActivate.
  ///
  /// In en, this message translates to:
  /// **'Activate'**
  String get subscriptionActivate;

  /// No description provided for @subscriptionActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get subscriptionActive;

  /// No description provided for @subscriptionSwitchedTo.
  ///
  /// In en, this message translates to:
  /// **'Switched to {name}'**
  String subscriptionSwitchedTo(String name);

  /// No description provided for @subscriptionCannotDeleteActive.
  ///
  /// In en, this message translates to:
  /// **'The active subscription can\'t be deleted. Switch to another source first.'**
  String get subscriptionCannotDeleteActive;

  /// No description provided for @subscriptionDeleteSelectedConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete the {count} selected subscriptions? This cannot be undone.'**
  String subscriptionDeleteSelectedConfirm(int count);

  /// No description provided for @subscriptionDeleteOneConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"? This cannot be undone.'**
  String subscriptionDeleteOneConfirm(String name);

  /// No description provided for @subscriptionUpToDate.
  ///
  /// In en, this message translates to:
  /// **'\"{name}\" is up to date'**
  String subscriptionUpToDate(String name);

  /// No description provided for @subscriptionUpdatedOne.
  ///
  /// In en, this message translates to:
  /// **'Updated to the latest version'**
  String get subscriptionUpdatedOne;

  /// No description provided for @subscriptionUpdatedCount.
  ///
  /// In en, this message translates to:
  /// **'Updated {count} subscriptions'**
  String subscriptionUpdatedCount(int count);

  /// No description provided for @subscriptionAllUpToDate.
  ///
  /// In en, this message translates to:
  /// **'All subscriptions are up to date'**
  String get subscriptionAllUpToDate;

  /// No description provided for @subscriptionCheckFailed.
  ///
  /// In en, this message translates to:
  /// **'Update check failed ({error})'**
  String subscriptionCheckFailed(String error);

  /// No description provided for @subscriptionChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking for subscription updates…'**
  String get subscriptionChecking;

  /// No description provided for @subscriptionEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit subscription'**
  String get subscriptionEdit;

  /// No description provided for @subscriptionFingerprint.
  ///
  /// In en, this message translates to:
  /// **'Content fingerprint'**
  String get subscriptionFingerprint;

  /// No description provided for @subscriptionReplaceZip.
  ///
  /// In en, this message translates to:
  /// **'Replace local script'**
  String get subscriptionReplaceZip;

  /// No description provided for @subscriptionReplaceZipSub.
  ///
  /// In en, this message translates to:
  /// **'Choose a zip archive again to overwrite the current local source'**
  String get subscriptionReplaceZipSub;

  /// No description provided for @subscriptionNotFound.
  ///
  /// In en, this message translates to:
  /// **'Subscription not found'**
  String get subscriptionNotFound;

  /// No description provided for @homeSwitchSite.
  ///
  /// In en, this message translates to:
  /// **'Switch site'**
  String get homeSwitchSite;

  /// No description provided for @homeSiteSettings.
  ///
  /// In en, this message translates to:
  /// **'Site settings'**
  String get homeSiteSettings;

  /// No description provided for @homeSiteEnable.
  ///
  /// In en, this message translates to:
  /// **'Enable'**
  String get homeSiteEnable;

  /// No description provided for @homeSiteHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get homeSiteHistory;

  /// No description provided for @homeSiteWebsite.
  ///
  /// In en, this message translates to:
  /// **'Web page'**
  String get homeSiteWebsite;

  /// No description provided for @homeSiteUnlock.
  ///
  /// In en, this message translates to:
  /// **'Unlock sites'**
  String get homeSiteUnlock;

  /// No description provided for @homeBlockCategories.
  ///
  /// In en, this message translates to:
  /// **'Block categories'**
  String get homeBlockCategories;

  /// No description provided for @homeHideFilters.
  ///
  /// In en, this message translates to:
  /// **'Hide filters'**
  String get homeHideFilters;

  /// No description provided for @homeShowFilters.
  ///
  /// In en, this message translates to:
  /// **'Show filters'**
  String get homeShowFilters;

  /// No description provided for @homeSwitchLayout.
  ///
  /// In en, this message translates to:
  /// **'Switch layout'**
  String get homeSwitchLayout;

  /// No description provided for @homeNoBlockableCategories.
  ///
  /// In en, this message translates to:
  /// **'This site has no categories left to block'**
  String get homeNoBlockableCategories;

  /// No description provided for @homePushNotSupported.
  ///
  /// In en, this message translates to:
  /// **'This subscription doesn\'t support push parsing'**
  String get homePushNotSupported;

  /// No description provided for @homePushTitle.
  ///
  /// In en, this message translates to:
  /// **'Push to parse'**
  String get homePushTitle;

  /// No description provided for @homePushHint.
  ///
  /// In en, this message translates to:
  /// **'Paste a share link…'**
  String get homePushHint;

  /// No description provided for @homePushDescription.
  ///
  /// In en, this message translates to:
  /// **'Paste a cloud-drive share link or a direct video link to resolve its play lines'**
  String get homePushDescription;

  /// No description provided for @homeNoSites.
  ///
  /// In en, this message translates to:
  /// **'No sites available. Add a subscription first.'**
  String get homeNoSites;

  /// No description provided for @detailPlayNow.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get detailPlayNow;

  /// No description provided for @detailEpisodes.
  ///
  /// In en, this message translates to:
  /// **'Episodes'**
  String get detailEpisodes;

  /// No description provided for @detailIntro.
  ///
  /// In en, this message translates to:
  /// **'Synopsis'**
  String get detailIntro;

  /// No description provided for @detailEpisodeSheetSub.
  ///
  /// In en, this message translates to:
  /// **'{line} · {count} episodes'**
  String detailEpisodeSheetSub(String line, int count);

  /// No description provided for @detailLocateCurrent.
  ///
  /// In en, this message translates to:
  /// **'Go to current episode'**
  String get detailLocateCurrent;

  /// No description provided for @detailReverseOrder.
  ///
  /// In en, this message translates to:
  /// **'Reverse order'**
  String get detailReverseOrder;

  /// No description provided for @searchEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Search videos'**
  String get searchEmptyTitle;

  /// No description provided for @mediaAccountsTitle.
  ///
  /// In en, this message translates to:
  /// **'Media server accounts'**
  String get mediaAccountsTitle;

  /// No description provided for @mediaEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Add an account to browse your Emby library'**
  String get mediaEmptySubtitle;

  /// No description provided for @mediaAddAccount.
  ///
  /// In en, this message translates to:
  /// **'Add account'**
  String get mediaAddAccount;

  /// No description provided for @mediaServerType.
  ///
  /// In en, this message translates to:
  /// **'Server type'**
  String get mediaServerType;

  /// No description provided for @mediaAutoDetect.
  ///
  /// In en, this message translates to:
  /// **'Auto-detect'**
  String get mediaAutoDetect;

  /// No description provided for @mediaAddressHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. http://192.168.1.10:8096'**
  String get mediaAddressHint;

  /// No description provided for @mediaPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'Optional'**
  String get mediaPasswordHint;

  /// No description provided for @mediaSignInAndSave.
  ///
  /// In en, this message translates to:
  /// **'Sign in and save'**
  String get mediaSignInAndSave;

  /// No description provided for @mediaAccountExists.
  ///
  /// In en, this message translates to:
  /// **'This account already exists'**
  String get mediaAccountExists;

  /// No description provided for @mediaSignedIn.
  ///
  /// In en, this message translates to:
  /// **'Signed in'**
  String get mediaSignedIn;

  /// No description provided for @mediaAddressRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter the server address'**
  String get mediaAddressRequired;

  /// No description provided for @mediaDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete “{name}”? You will need to sign in again to use this server.'**
  String mediaDeleteConfirm(String name);

  /// No description provided for @tmdbConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get tmdbConnect;

  /// No description provided for @tmdbGetKey.
  ///
  /// In en, this message translates to:
  /// **'Get an API key'**
  String get tmdbGetKey;

  /// No description provided for @tmdbConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected to TMDB'**
  String get tmdbConnected;

  /// No description provided for @tmdbDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get tmdbDisconnect;

  /// No description provided for @tmdbDisconnectTitle.
  ///
  /// In en, this message translates to:
  /// **'Disconnect TMDB?'**
  String get tmdbDisconnectTitle;

  /// No description provided for @tmdbDisconnectBody.
  ///
  /// In en, this message translates to:
  /// **'The API key is cleared and TMDB is turned off; the proxy settings are kept.'**
  String get tmdbDisconnectBody;

  /// No description provided for @tmdbProxyGroup.
  ///
  /// In en, this message translates to:
  /// **'Proxy and advanced'**
  String get tmdbProxyGroup;

  /// No description provided for @webdavEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'WebDAV sync is not set up'**
  String get webdavEmptyTitle;

  /// No description provided for @webdavEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Add a server address, account and password to sync your data between devices'**
  String get webdavEmptySubtitle;

  /// No description provided for @webdavAddConfig.
  ///
  /// In en, this message translates to:
  /// **'Add configuration'**
  String get webdavAddConfig;

  /// No description provided for @webdavConfigTitle.
  ///
  /// In en, this message translates to:
  /// **'WebDAV configuration'**
  String get webdavConfigTitle;

  /// No description provided for @webdavEditConfig.
  ///
  /// In en, this message translates to:
  /// **'Edit configuration'**
  String get webdavEditConfig;

  /// No description provided for @webdavIsolation.
  ///
  /// In en, this message translates to:
  /// **'Isolation name'**
  String get webdavIsolation;

  /// No description provided for @webdavIsolationHint.
  ///
  /// In en, this message translates to:
  /// **'Keeps data apart when several people share one WebDAV; empty = root folder'**
  String get webdavIsolationHint;

  /// No description provided for @webdavServiceAddress.
  ///
  /// In en, this message translates to:
  /// **'Service address'**
  String get webdavServiceAddress;

  /// No description provided for @webdavServiceAddressHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. https://dav.jianguoyun.com/dav/'**
  String get webdavServiceAddressHint;

  /// No description provided for @webdavAccountLabel.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get webdavAccountLabel;

  /// No description provided for @webdavAccountHint.
  ///
  /// In en, this message translates to:
  /// **'WebDAV user name'**
  String get webdavAccountHint;

  /// No description provided for @webdavPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'App password'**
  String get webdavPasswordHint;

  /// No description provided for @webdavFillRequired.
  ///
  /// In en, this message translates to:
  /// **'Fill in the service address, account and password first'**
  String get webdavFillRequired;

  /// No description provided for @webdavConnectFailed.
  ///
  /// In en, this message translates to:
  /// **'WebDAV connection failed'**
  String get webdavConnectFailed;

  /// No description provided for @webdavAuthFailed.
  ///
  /// In en, this message translates to:
  /// **'WebDAV authentication failed, check the account and password'**
  String get webdavAuthFailed;

  /// No description provided for @webdavEnableSync.
  ///
  /// In en, this message translates to:
  /// **'Enable sync'**
  String get webdavEnableSync;

  /// No description provided for @webdavEnableSyncSub.
  ///
  /// In en, this message translates to:
  /// **'Sync the selected data when the app starts'**
  String get webdavEnableSyncSub;

  /// No description provided for @webdavSyncing.
  ///
  /// In en, this message translates to:
  /// **'Syncing…'**
  String get webdavSyncing;

  /// No description provided for @webdavNeverSynced.
  ///
  /// In en, this message translates to:
  /// **'Not synced yet'**
  String get webdavNeverSynced;

  /// No description provided for @webdavLastSync.
  ///
  /// In en, this message translates to:
  /// **'Last sync {time}'**
  String webdavLastSync(String time);

  /// No description provided for @webdavSyncDone.
  ///
  /// In en, this message translates to:
  /// **'Sync complete'**
  String get webdavSyncDone;

  /// No description provided for @webdavSyncFailed.
  ///
  /// In en, this message translates to:
  /// **'WebDAV sync failed: {error}'**
  String webdavSyncFailed(String error);

  /// No description provided for @webdavNoTypes.
  ///
  /// In en, this message translates to:
  /// **'No data type selected'**
  String get webdavNoTypes;

  /// No description provided for @webdavTypesGroup.
  ///
  /// In en, this message translates to:
  /// **'What to sync'**
  String get webdavTypesGroup;

  /// No description provided for @webdavTypeFavorites.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get webdavTypeFavorites;

  /// No description provided for @webdavTypeFavoritesSub.
  ///
  /// In en, this message translates to:
  /// **'Favorites and the calendar auto-sync switch'**
  String get webdavTypeFavoritesSub;

  /// No description provided for @webdavTypeHistory.
  ///
  /// In en, this message translates to:
  /// **'History and progress'**
  String get webdavTypeHistory;

  /// No description provided for @webdavTypeHistorySub.
  ///
  /// In en, this message translates to:
  /// **'Watch history, playback positions and last episodes'**
  String get webdavTypeHistorySub;

  /// No description provided for @webdavTypeTracking.
  ///
  /// In en, this message translates to:
  /// **'Tracked shows'**
  String get webdavTypeTracking;

  /// No description provided for @webdavTypeTrackingSub.
  ///
  /// In en, this message translates to:
  /// **'Shows on the calendar'**
  String get webdavTypeTrackingSub;

  /// No description provided for @webdavTypeTmdb.
  ///
  /// In en, this message translates to:
  /// **'TMDB'**
  String get webdavTypeTmdb;

  /// No description provided for @webdavTypeTmdbSub.
  ///
  /// In en, this message translates to:
  /// **'TMDB switch, API key and proxy addresses (replaced as a group) plus match records; the API key is stored in plain text on the WebDAV server'**
  String get webdavTypeTmdbSub;

  /// No description provided for @webdavTypePlayer.
  ///
  /// In en, this message translates to:
  /// **'Player settings'**
  String get webdavTypePlayer;

  /// No description provided for @webdavTypePlayerSub.
  ///
  /// In en, this message translates to:
  /// **'Player settings and intro/outro records'**
  String get webdavTypePlayerSub;

  /// No description provided for @webdavTypeLive.
  ///
  /// In en, this message translates to:
  /// **'Live TV'**
  String get webdavTypeLive;

  /// No description provided for @webdavTypeLiveSub.
  ///
  /// In en, this message translates to:
  /// **'Live sources, global EPG and hidden categories'**
  String get webdavTypeLiveSub;

  /// No description provided for @liveGlobalEpg.
  ///
  /// In en, this message translates to:
  /// **'Global EPG URL'**
  String get liveGlobalEpg;

  /// No description provided for @liveGlobalEpgHint.
  ///
  /// In en, this message translates to:
  /// **'Used when a source has no EPG of its own, e.g. https://example.com/epg.xml.gz'**
  String get liveGlobalEpgHint;

  /// No description provided for @liveEpgSaved.
  ///
  /// In en, this message translates to:
  /// **'EPG URL saved'**
  String get liveEpgSaved;

  /// No description provided for @liveSourceUrl.
  ///
  /// In en, this message translates to:
  /// **'Source URL'**
  String get liveSourceUrl;

  /// No description provided for @liveNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. My live TV'**
  String get liveNameHint;

  /// No description provided for @liveM3uOnly.
  ///
  /// In en, this message translates to:
  /// **'Only M3U playlists are supported'**
  String get liveM3uOnly;

  /// No description provided for @liveAutoRefresh.
  ///
  /// In en, this message translates to:
  /// **'Auto refresh'**
  String get liveAutoRefresh;

  /// No description provided for @liveRefreshOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get liveRefreshOff;

  /// No description provided for @liveRefreshAlways.
  ///
  /// In en, this message translates to:
  /// **'Every time'**
  String get liveRefreshAlways;

  /// No description provided for @liveRefresh24h.
  ///
  /// In en, this message translates to:
  /// **'24 hours'**
  String get liveRefresh24h;

  /// No description provided for @liveVerifyAndSave.
  ///
  /// In en, this message translates to:
  /// **'Verify and save'**
  String get liveVerifyAndSave;

  /// No description provided for @liveSourceSaved.
  ///
  /// In en, this message translates to:
  /// **'Live source saved'**
  String get liveSourceSaved;

  /// No description provided for @liveSourceSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save the live source: {error}'**
  String liveSourceSaveFailed(String error);

  /// No description provided for @liveSourceExists.
  ///
  /// In en, this message translates to:
  /// **'A live source with this address already exists'**
  String get liveSourceExists;

  /// No description provided for @liveDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete the live source “{name}”?'**
  String liveDeleteConfirm(String name);

  /// No description provided for @liveSourceDeleted.
  ///
  /// In en, this message translates to:
  /// **'Live source deleted'**
  String get liveSourceDeleted;

  /// No description provided for @liveBlockedEmpty.
  ///
  /// In en, this message translates to:
  /// **'No hidden categories'**
  String get liveBlockedEmpty;

  /// No description provided for @liveBlockPick.
  ///
  /// In en, this message translates to:
  /// **'Hide a category'**
  String get liveBlockPick;

  /// No description provided for @liveNothingToBlock.
  ///
  /// In en, this message translates to:
  /// **'No category left to hide'**
  String get liveNothingToBlock;

  /// No description provided for @liveCategoryBlocked.
  ///
  /// In en, this message translates to:
  /// **'Hid “{name}”'**
  String liveCategoryBlocked(String name);

  /// No description provided for @liveCategoryUnblocked.
  ///
  /// In en, this message translates to:
  /// **'Showing “{name}” again'**
  String liveCategoryUnblocked(String name);

  /// No description provided for @liveUserAgentHint.
  ///
  /// In en, this message translates to:
  /// **'Custom User-Agent'**
  String get liveUserAgentHint;

  /// No description provided for @danmuStatus.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get danmuStatus;

  /// No description provided for @danmuStopped.
  ///
  /// In en, this message translates to:
  /// **'Stopped'**
  String get danmuStopped;

  /// No description provided for @danmuRunning.
  ///
  /// In en, this message translates to:
  /// **'Running: {port}'**
  String danmuRunning(String port);

  /// No description provided for @danmuNoService.
  ///
  /// In en, this message translates to:
  /// **'No danmaku service yet'**
  String get danmuNoService;

  /// No description provided for @danmuNoServiceSub.
  ///
  /// In en, this message translates to:
  /// **'Add a network source or a local script below'**
  String get danmuNoServiceSub;

  /// No description provided for @danmuOpenWeb.
  ///
  /// In en, this message translates to:
  /// **'Open web page'**
  String get danmuOpenWeb;

  /// No description provided for @danmuRestart.
  ///
  /// In en, this message translates to:
  /// **'Restart service'**
  String get danmuRestart;

  /// No description provided for @danmuStop.
  ///
  /// In en, this message translates to:
  /// **'Stop service'**
  String get danmuStop;

  /// No description provided for @danmuNotReady.
  ///
  /// In en, this message translates to:
  /// **'The service is not ready, cannot open the page'**
  String get danmuNotReady;

  /// No description provided for @danmuNetworkSource.
  ///
  /// In en, this message translates to:
  /// **'Network source'**
  String get danmuNetworkSource;

  /// No description provided for @danmuLocalScriptTab.
  ///
  /// In en, this message translates to:
  /// **'Local script'**
  String get danmuLocalScriptTab;

  /// No description provided for @danmuSourceUrl.
  ///
  /// In en, this message translates to:
  /// **'Source URL (.cjs.md5)'**
  String get danmuSourceUrl;

  /// No description provided for @danmuDownload.
  ///
  /// In en, this message translates to:
  /// **'Download script'**
  String get danmuDownload;

  /// No description provided for @danmuLoadLocal.
  ///
  /// In en, this message translates to:
  /// **'Load local script'**
  String get danmuLoadLocal;

  /// No description provided for @danmuReplaceLocal.
  ///
  /// In en, this message translates to:
  /// **'Replace local script'**
  String get danmuReplaceLocal;

  /// No description provided for @danmuLocalLoaded.
  ///
  /// In en, this message translates to:
  /// **'Local script loaded'**
  String get danmuLocalLoaded;

  /// No description provided for @danmuLocalOnlyCjs.
  ///
  /// In en, this message translates to:
  /// **'Only .cjs/.js files (got: {name})'**
  String danmuLocalOnlyCjs(String name);

  /// No description provided for @danmuRemoteHint.
  ///
  /// In en, this message translates to:
  /// **'http://ip:9321 or http://ip:9321/TOKEN'**
  String get danmuRemoteHint;

  /// No description provided for @danmuShowTop.
  ///
  /// In en, this message translates to:
  /// **'Show top danmaku'**
  String get danmuShowTop;

  /// No description provided for @danmuShowBottom.
  ///
  /// In en, this message translates to:
  /// **'Show bottom danmaku'**
  String get danmuShowBottom;

  /// No description provided for @danmuShowPositionSub.
  ///
  /// In en, this message translates to:
  /// **'When off, these scroll instead'**
  String get danmuShowPositionSub;

  /// No description provided for @danmuColor.
  ///
  /// In en, this message translates to:
  /// **'Danmaku colour'**
  String get danmuColor;

  /// No description provided for @danmuColorOriginal.
  ///
  /// In en, this message translates to:
  /// **'Own colours'**
  String get danmuColorOriginal;

  /// No description provided for @danmuColorWhite.
  ///
  /// In en, this message translates to:
  /// **'White'**
  String get danmuColorWhite;

  /// No description provided for @danmuColorRandom.
  ///
  /// In en, this message translates to:
  /// **'Random (solid)'**
  String get danmuColorRandom;

  /// No description provided for @danmuLineHeight.
  ///
  /// In en, this message translates to:
  /// **'Line spacing'**
  String get danmuLineHeight;

  /// No description provided for @danmuStroke.
  ///
  /// In en, this message translates to:
  /// **'Outline'**
  String get danmuStroke;

  /// No description provided for @danmuBlockedWordsTitle.
  ///
  /// In en, this message translates to:
  /// **'Blocked words'**
  String get danmuBlockedWordsTitle;

  /// No description provided for @danmuBlockedWordsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No blocked words; danmaku containing one are filtered out'**
  String get danmuBlockedWordsEmpty;

  /// No description provided for @danmuBlockedWordAdd.
  ///
  /// In en, this message translates to:
  /// **'Add blocked word'**
  String get danmuBlockedWordAdd;

  /// No description provided for @playerGroupDecode.
  ///
  /// In en, this message translates to:
  /// **'Decoding'**
  String get playerGroupDecode;

  /// No description provided for @playerGroupPicture.
  ///
  /// In en, this message translates to:
  /// **'Picture and engine'**
  String get playerGroupPicture;

  /// No description provided for @playerHwDecodeSub.
  ///
  /// In en, this message translates to:
  /// **'Off: software decoding (more compatible, uses more power)'**
  String get playerHwDecodeSub;

  /// No description provided for @playerShowTotalDurationSub.
  ///
  /// In en, this message translates to:
  /// **'Off: show the remaining time'**
  String get playerShowTotalDurationSub;

  /// No description provided for @playerAutoPipSub.
  ///
  /// In en, this message translates to:
  /// **'Keep playing in picture-in-picture when you leave the app'**
  String get playerAutoPipSub;

  /// No description provided for @playerSkipNoticeSub.
  ///
  /// In en, this message translates to:
  /// **'Show a banner and a short notice when intros/outros are skipped'**
  String get playerSkipNoticeSub;

  /// No description provided for @playerEpisodeSwitchNoticeSub.
  ///
  /// In en, this message translates to:
  /// **'Show “Switching to episode x” when the episode changes'**
  String get playerEpisodeSwitchNoticeSub;

  /// No description provided for @playerShowStatsSub.
  ///
  /// In en, this message translates to:
  /// **'Costs some performance'**
  String get playerShowStatsSub;

  /// No description provided for @playerShowNetSpeedSub.
  ///
  /// In en, this message translates to:
  /// **'See the download speed without opening the info bar'**
  String get playerShowNetSpeedSub;

  /// No description provided for @backupExportItems.
  ///
  /// In en, this message translates to:
  /// **'Choose data and export'**
  String get backupExportItems;

  /// No description provided for @backupExportItemsSub.
  ///
  /// In en, this message translates to:
  /// **'Packed as a zip into Backups'**
  String get backupExportItemsSub;

  /// No description provided for @backupRestoreFile.
  ///
  /// In en, this message translates to:
  /// **'Restore from a backup file'**
  String get backupRestoreFile;

  /// No description provided for @backupRestoreFileSub.
  ///
  /// In en, this message translates to:
  /// **'Overwrite data from a zip backup (older JSON backups work too)'**
  String get backupRestoreFileSub;

  /// No description provided for @backupSheetDescription.
  ///
  /// In en, this message translates to:
  /// **'Tick the data to export. Subscriptions, settings and accounts may contain account names, passwords or tokens, written in plain text into the backup file.'**
  String get backupSheetDescription;

  /// No description provided for @backupSensitiveWarning.
  ///
  /// In en, this message translates to:
  /// **'The selected data contains accounts, passwords or tokens, written in plain text into the backup file. Keep it safe and share it with care.'**
  String get backupSensitiveWarning;

  /// No description provided for @backupExportButton.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get backupExportButton;

  /// No description provided for @backupGroupUser.
  ///
  /// In en, this message translates to:
  /// **'User data'**
  String get backupGroupUser;

  /// No description provided for @backupGroupSubscriptions.
  ///
  /// In en, this message translates to:
  /// **'Subscriptions and danmaku'**
  String get backupGroupSubscriptions;

  /// No description provided for @backupGroupPreferences.
  ///
  /// In en, this message translates to:
  /// **'Preferences'**
  String get backupGroupPreferences;

  /// No description provided for @backupItemHistory.
  ///
  /// In en, this message translates to:
  /// **'Watch history'**
  String get backupItemHistory;

  /// No description provided for @backupItemFavorites.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get backupItemFavorites;

  /// No description provided for @backupItemProgress.
  ///
  /// In en, this message translates to:
  /// **'Playback progress'**
  String get backupItemProgress;

  /// No description provided for @backupItemLastEpisode.
  ///
  /// In en, this message translates to:
  /// **'Last episodes'**
  String get backupItemLastEpisode;

  /// No description provided for @backupItemTmdbRefs.
  ///
  /// In en, this message translates to:
  /// **'TMDB matches'**
  String get backupItemTmdbRefs;

  /// No description provided for @backupItemHeadTail.
  ///
  /// In en, this message translates to:
  /// **'Intros and outros'**
  String get backupItemHeadTail;

  /// No description provided for @backupItemTracking.
  ///
  /// In en, this message translates to:
  /// **'Tracked shows'**
  String get backupItemTracking;

  /// No description provided for @backupItemDanmuRefs.
  ///
  /// In en, this message translates to:
  /// **'Danmaku matches'**
  String get backupItemDanmuRefs;

  /// No description provided for @backupItemLive.
  ///
  /// In en, this message translates to:
  /// **'Live sources'**
  String get backupItemLive;

  /// No description provided for @backupItemSubscriptions.
  ///
  /// In en, this message translates to:
  /// **'Subscription list'**
  String get backupItemSubscriptions;

  /// No description provided for @backupItemAppSettings.
  ///
  /// In en, this message translates to:
  /// **'App settings (with danmaku service)'**
  String get backupItemAppSettings;

  /// No description provided for @backupItemAccounts.
  ///
  /// In en, this message translates to:
  /// **'Media server and WebDAV accounts'**
  String get backupItemAccounts;

  /// No description provided for @backupRestoreWebdavTitle.
  ///
  /// In en, this message translates to:
  /// **'Restore from WebDAV'**
  String get backupRestoreWebdavTitle;

  /// No description provided for @webSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Enter a URL or search words'**
  String get webSearchHint;

  /// No description provided for @webGo.
  ///
  /// In en, this message translates to:
  /// **'Go'**
  String get webGo;

  /// No description provided for @webClearList.
  ///
  /// In en, this message translates to:
  /// **'Clear list'**
  String get webClearList;

  /// No description provided for @webOpenExternal.
  ///
  /// In en, this message translates to:
  /// **'Open in external browser'**
  String get webOpenExternal;

  /// No description provided for @webClearCookies.
  ///
  /// In en, this message translates to:
  /// **'Clear web cookies'**
  String get webClearCookies;

  /// No description provided for @webCookiesCleared.
  ///
  /// In en, this message translates to:
  /// **'WebView cookies cleared'**
  String get webCookiesCleared;

  /// No description provided for @webUaDefault.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get webUaDefault;

  /// No description provided for @webUaDesktop.
  ///
  /// In en, this message translates to:
  /// **'Desktop Chrome'**
  String get webUaDesktop;

  /// No description provided for @webUaCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom…'**
  String get webUaCustom;

  /// No description provided for @webReload.
  ///
  /// In en, this message translates to:
  /// **'Reload'**
  String get webReload;

  /// No description provided for @webSniffed.
  ///
  /// In en, this message translates to:
  /// **'Found media'**
  String get webSniffed;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'Follow system'**
  String get languageSystem;

  /// No description provided for @languageZh.
  ///
  /// In en, this message translates to:
  /// **'简体中文'**
  String get languageZh;

  /// No description provided for @languageEn.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEn;

  /// No description provided for @settingsTheme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get settingsTheme;

  /// No description provided for @settingsThemeSub.
  ///
  /// In en, this message translates to:
  /// **'Color, dark style, font size'**
  String get settingsThemeSub;

  /// No description provided for @themeCustomize.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get themeCustomize;

  /// No description provided for @themeModeLabel.
  ///
  /// In en, this message translates to:
  /// **'Theme mode'**
  String get themeModeLabel;

  /// No description provided for @themeAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get themeAuto;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @themeDarkStyle.
  ///
  /// In en, this message translates to:
  /// **'Dark background'**
  String get themeDarkStyle;

  /// No description provided for @themeDarkGray.
  ///
  /// In en, this message translates to:
  /// **'Dark grey'**
  String get themeDarkGray;

  /// No description provided for @themeDarkBlack.
  ///
  /// In en, this message translates to:
  /// **'Pure black'**
  String get themeDarkBlack;

  /// No description provided for @themeFontSize.
  ///
  /// In en, this message translates to:
  /// **'Font size'**
  String get themeFontSize;

  /// No description provided for @settingsFeatures.
  ///
  /// In en, this message translates to:
  /// **'Features'**
  String get settingsFeatures;

  /// No description provided for @settingsFeaturesSub.
  ///
  /// In en, this message translates to:
  /// **'Behaviour and switches'**
  String get settingsFeaturesSub;

  /// No description provided for @catpawTimeout.
  ///
  /// In en, this message translates to:
  /// **'catpaw service timeout'**
  String get catpawTimeout;

  /// No description provided for @catpawTimeoutSub.
  ///
  /// In en, this message translates to:
  /// **'How long to wait for catpaw data'**
  String get catpawTimeoutSub;

  /// No description provided for @catpawTimeoutField.
  ///
  /// In en, this message translates to:
  /// **'Receive timeout (s)'**
  String get catpawTimeoutField;

  /// No description provided for @settingsCleanup.
  ///
  /// In en, this message translates to:
  /// **'Clean up data'**
  String get settingsCleanup;

  /// No description provided for @settingsCleanupSub.
  ///
  /// In en, this message translates to:
  /// **'Choose what to clear'**
  String get settingsCleanupSub;

  /// No description provided for @cleanupDescription.
  ///
  /// In en, this message translates to:
  /// **'Tick the items to clear, then tap the button below.'**
  String get cleanupDescription;

  /// No description provided for @cleanupGroupCache.
  ///
  /// In en, this message translates to:
  /// **'Cache'**
  String get cleanupGroupCache;

  /// No description provided for @cleanupImages.
  ///
  /// In en, this message translates to:
  /// **'Image cache'**
  String get cleanupImages;

  /// No description provided for @cleanupTemp.
  ///
  /// In en, this message translates to:
  /// **'Temporary files'**
  String get cleanupTemp;

  /// No description provided for @cleanupLivePlaylists.
  ///
  /// In en, this message translates to:
  /// **'Live playlist cache'**
  String get cleanupLivePlaylists;

  /// No description provided for @cleanupRun.
  ///
  /// In en, this message translates to:
  /// **'Clear selected'**
  String get cleanupRun;

  /// No description provided for @cleanupDone.
  ///
  /// In en, this message translates to:
  /// **'Cleared {count} item(s)'**
  String cleanupDone(int count);

  /// No description provided for @cleanupFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not clear: {error}'**
  String cleanupFailed(String error);

  /// No description provided for @settingsHomeTabs.
  ///
  /// In en, this message translates to:
  /// **'Home pages'**
  String get settingsHomeTabs;

  /// No description provided for @settingsHomeTabsSub.
  ///
  /// In en, this message translates to:
  /// **'Choose the pages on the bottom bar and their order'**
  String get settingsHomeTabsSub;

  /// No description provided for @homeTabsEnabled.
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get homeTabsEnabled;

  /// No description provided for @homeTabsDisabled.
  ///
  /// In en, this message translates to:
  /// **'Not enabled'**
  String get homeTabsDisabled;

  /// No description provided for @homeTabsHint.
  ///
  /// In en, this message translates to:
  /// **'Long-press and drag to reorder'**
  String get homeTabsHint;

  /// No description provided for @homeTabsRequired.
  ///
  /// In en, this message translates to:
  /// **'Required page, cannot be turned off'**
  String get homeTabsRequired;

  /// No description provided for @downloadsManage.
  ///
  /// In en, this message translates to:
  /// **'Downloads'**
  String get downloadsManage;

  /// No description provided for @mediaManageAccounts.
  ///
  /// In en, this message translates to:
  /// **'Manage accounts'**
  String get mediaManageAccounts;

  /// No description provided for @lockPassword.
  ///
  /// In en, this message translates to:
  /// **'Lock password'**
  String get lockPassword;

  /// No description provided for @lockNotSet.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get lockNotSet;

  /// No description provided for @lockSet.
  ///
  /// In en, this message translates to:
  /// **'Set'**
  String get lockSet;

  /// No description provided for @lockEmpty.
  ///
  /// In en, this message translates to:
  /// **'Empty password'**
  String get lockEmpty;

  /// No description provided for @lockStateNotSet.
  ///
  /// In en, this message translates to:
  /// **'No lock password has been set'**
  String get lockStateNotSet;

  /// No description provided for @lockStateSet.
  ///
  /// In en, this message translates to:
  /// **'A lock password is set'**
  String get lockStateSet;

  /// No description provided for @lockStateEmpty.
  ///
  /// In en, this message translates to:
  /// **'The password is empty (no protection)'**
  String get lockStateEmpty;

  /// No description provided for @lockStepNew.
  ///
  /// In en, this message translates to:
  /// **'Enter a new password'**
  String get lockStepNew;

  /// No description provided for @lockStepConfirm.
  ///
  /// In en, this message translates to:
  /// **'Enter it again to confirm'**
  String get lockStepConfirm;

  /// No description provided for @lockStepOld.
  ///
  /// In en, this message translates to:
  /// **'Verify the old password'**
  String get lockStepOld;

  /// No description provided for @lockTapHint.
  ///
  /// In en, this message translates to:
  /// **'Tap the colour tiles to enter the password'**
  String get lockTapHint;

  /// No description provided for @lockTooShort.
  ///
  /// In en, this message translates to:
  /// **'Enter at least one digit'**
  String get lockTooShort;

  /// No description provided for @lockMismatch.
  ///
  /// In en, this message translates to:
  /// **'The two entries differ, please try again'**
  String get lockMismatch;

  /// No description provided for @lockWrongOld.
  ///
  /// In en, this message translates to:
  /// **'Wrong old password'**
  String get lockWrongOld;

  /// No description provided for @lockUpdated.
  ///
  /// In en, this message translates to:
  /// **'Lock password updated'**
  String get lockUpdated;

  /// No description provided for @lockCleared.
  ///
  /// In en, this message translates to:
  /// **'Lock password cleared'**
  String get lockCleared;

  /// No description provided for @lockSetEmpty.
  ///
  /// In en, this message translates to:
  /// **'Set to an empty password'**
  String get lockSetEmpty;

  /// No description provided for @lockVerifyTitle.
  ///
  /// In en, this message translates to:
  /// **'Verify lock password'**
  String get lockVerifyTitle;

  /// No description provided for @lockFirstTitle.
  ///
  /// In en, this message translates to:
  /// **'First lock'**
  String get lockFirstTitle;

  /// No description provided for @lockFirstBody.
  ///
  /// In en, this message translates to:
  /// **'Set a lock password? Without one an empty password is used (no protection).'**
  String get lockFirstBody;

  /// No description provided for @lockSkip.
  ///
  /// In en, this message translates to:
  /// **'Don\'t set'**
  String get lockSkip;

  /// No description provided for @lockClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get lockClear;

  /// No description provided for @lockNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get lockNext;

  /// No description provided for @lockConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get lockConfirm;

  /// No description provided for @lockUnlock.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get lockUnlock;

  /// No description provided for @lockHiddenSubscriptions.
  ///
  /// In en, this message translates to:
  /// **'Locked subscriptions are hidden'**
  String get lockHiddenSubscriptions;

  /// No description provided for @lockUnlockSubscriptions.
  ///
  /// In en, this message translates to:
  /// **'Unlock subscriptions'**
  String get lockUnlockSubscriptions;

  /// No description provided for @lockRelock.
  ///
  /// In en, this message translates to:
  /// **'Lock again'**
  String get lockRelock;

  /// No description provided for @lockHomeTitle.
  ///
  /// In en, this message translates to:
  /// **'Subscription locked'**
  String get lockHomeTitle;

  /// No description provided for @lockHomeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'The current subscription is locked; unlock it to view'**
  String get lockHomeSubtitle;

  /// No description provided for @lockBackspace.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get lockBackspace;

  /// No description provided for @settingsReset.
  ///
  /// In en, this message translates to:
  /// **'Reset app'**
  String get settingsReset;

  /// No description provided for @settingsResetSub.
  ///
  /// In en, this message translates to:
  /// **'Erase all data and restart'**
  String get settingsResetSub;

  /// No description provided for @resetConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'All local data (subscriptions, history, favourites, settings, fonts, downloads, catpaw instance data and everything else) will be erased and the app restarted, like a factory reset. Exported backup files are kept. This cannot be undone. Continue?'**
  String get resetConfirmBody;

  /// No description provided for @resetInProgress.
  ///
  /// In en, this message translates to:
  /// **'Resetting…'**
  String get resetInProgress;

  /// No description provided for @resetDone.
  ///
  /// In en, this message translates to:
  /// **'All data has been erased. The app will now close; please open it again.'**
  String get resetDone;

  /// No description provided for @resetFailed.
  ///
  /// In en, this message translates to:
  /// **'Reset failed, please try again'**
  String get resetFailed;

  /// No description provided for @settingsGroupDeveloper.
  ///
  /// In en, this message translates to:
  /// **'Developer'**
  String get settingsGroupDeveloper;

  /// No description provided for @settingsCatpawDebug.
  ///
  /// In en, this message translates to:
  /// **'catpaw Debug'**
  String get settingsCatpawDebug;

  /// No description provided for @settingsCatpawDebugSub.
  ///
  /// In en, this message translates to:
  /// **'Start & manage catpaw instances, view logs'**
  String get settingsCatpawDebugSub;

  /// No description provided for @debugTitle.
  ///
  /// In en, this message translates to:
  /// **'catpaw multi-instance'**
  String get debugTitle;

  /// No description provided for @debugStartTitle.
  ///
  /// In en, this message translates to:
  /// **'Start catpaw Runtime'**
  String get debugStartTitle;

  /// No description provided for @debugStartSub.
  ///
  /// In en, this message translates to:
  /// **'Start the embedded Node runtime to load and manage catpaw instances and generic services'**
  String get debugStartSub;

  /// No description provided for @debugDartPort.
  ///
  /// In en, this message translates to:
  /// **'Dart callback port (empty=random)'**
  String get debugDartPort;

  /// No description provided for @debugStartNode.
  ///
  /// In en, this message translates to:
  /// **'Start Node'**
  String get debugStartNode;

  /// No description provided for @debugNodeStarting.
  ///
  /// In en, this message translates to:
  /// **'Node.js is starting…'**
  String get debugNodeStarting;

  /// No description provided for @debugNodeRunning.
  ///
  /// In en, this message translates to:
  /// **'Node running'**
  String get debugNodeRunning;

  /// No description provided for @debugLastResult.
  ///
  /// In en, this message translates to:
  /// **'Last result'**
  String get debugLastResult;

  /// No description provided for @debugCopyLast.
  ///
  /// In en, this message translates to:
  /// **'Copy Last'**
  String get debugCopyLast;

  /// No description provided for @debugCopiedLast.
  ///
  /// In en, this message translates to:
  /// **'Copied Last'**
  String get debugCopiedLast;

  /// No description provided for @debugLog.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get debugLog;

  /// No description provided for @debugNoLogs.
  ///
  /// In en, this message translates to:
  /// **'No logs'**
  String get debugNoLogs;

  /// No description provided for @debugCopyAllLogs.
  ///
  /// In en, this message translates to:
  /// **'Copy all logs'**
  String get debugCopyAllLogs;

  /// No description provided for @debugClearLogs.
  ///
  /// In en, this message translates to:
  /// **'Clear logs'**
  String get debugClearLogs;

  /// No description provided for @debugLogsCleared.
  ///
  /// In en, this message translates to:
  /// **'Logs cleared'**
  String get debugLogsCleared;

  /// No description provided for @debugTabServices.
  ///
  /// In en, this message translates to:
  /// **'Generic service'**
  String get debugTabServices;

  /// No description provided for @debugLoadInstance.
  ///
  /// In en, this message translates to:
  /// **'Load instance'**
  String get debugLoadInstance;

  /// No description provided for @debugInstanceName.
  ///
  /// In en, this message translates to:
  /// **'Instance name (storage key, defaults to URL account)'**
  String get debugInstanceName;

  /// No description provided for @debugPort.
  ///
  /// In en, this message translates to:
  /// **'Port (empty=random)'**
  String get debugPort;

  /// No description provided for @debugForceRestart.
  ///
  /// In en, this message translates to:
  /// **'Force restart if exists'**
  String get debugForceRestart;

  /// No description provided for @debugNetAudit.
  ///
  /// In en, this message translates to:
  /// **'Network audit (log outbound requests)'**
  String get debugNetAudit;

  /// No description provided for @debugServiceLog.
  ///
  /// In en, this message translates to:
  /// **'Service log (forward console)'**
  String get debugServiceLog;

  /// No description provided for @debugLoadButton.
  ///
  /// In en, this message translates to:
  /// **'Load catpaw instance'**
  String get debugLoadButton;

  /// No description provided for @debugRunningInstances.
  ///
  /// In en, this message translates to:
  /// **'Running instances'**
  String get debugRunningInstances;

  /// No description provided for @debugNoInstance.
  ///
  /// In en, this message translates to:
  /// **'No instance'**
  String get debugNoInstance;

  /// No description provided for @debugTest.
  ///
  /// In en, this message translates to:
  /// **'Test'**
  String get debugTest;

  /// No description provided for @debugStop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get debugStop;

  /// No description provided for @debugInstallService.
  ///
  /// In en, this message translates to:
  /// **'Install service'**
  String get debugInstallService;

  /// No description provided for @debugServiceUrl.
  ///
  /// In en, this message translates to:
  /// **'Generic service index.js URL'**
  String get debugServiceUrl;

  /// No description provided for @debugServiceName.
  ///
  /// In en, this message translates to:
  /// **'Service name (storage key, blank=from URL)'**
  String get debugServiceName;

  /// No description provided for @debugDefaultPort.
  ///
  /// In en, this message translates to:
  /// **'Default port (blank=script default)'**
  String get debugDefaultPort;

  /// No description provided for @debugLoadLocalScript.
  ///
  /// In en, this message translates to:
  /// **'Load local script'**
  String get debugLoadLocalScript;

  /// No description provided for @debugRegisteredServices.
  ///
  /// In en, this message translates to:
  /// **'Registered services'**
  String get debugRegisteredServices;

  /// No description provided for @debugNoService.
  ///
  /// In en, this message translates to:
  /// **'No service'**
  String get debugNoService;

  /// No description provided for @debugStartService.
  ///
  /// In en, this message translates to:
  /// **'Start service'**
  String get debugStartService;

  /// No description provided for @debugStopService.
  ///
  /// In en, this message translates to:
  /// **'Stop service'**
  String get debugStopService;

  /// No description provided for @debugUninstallService.
  ///
  /// In en, this message translates to:
  /// **'Uninstall service'**
  String get debugUninstallService;

  /// No description provided for @themeColor.
  ///
  /// In en, this message translates to:
  /// **'Theme color'**
  String get themeColor;

  /// No description provided for @fontCardTitle.
  ///
  /// In en, this message translates to:
  /// **'Fonts'**
  String get fontCardTitle;

  /// No description provided for @fontDefault.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get fontDefault;

  /// No description provided for @fontImport.
  ///
  /// In en, this message translates to:
  /// **'Import font'**
  String get fontImport;

  /// No description provided for @fontImported.
  ///
  /// In en, this message translates to:
  /// **'Font imported'**
  String get fontImported;

  /// No description provided for @fontImportFailed.
  ///
  /// In en, this message translates to:
  /// **'Font import failed'**
  String get fontImportFailed;

  /// No description provided for @fontExists.
  ///
  /// In en, this message translates to:
  /// **'This font already exists'**
  String get fontExists;

  /// No description provided for @fontDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete font'**
  String get fontDelete;

  /// No description provided for @fontDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete this font?'**
  String get fontDeleteConfirm;

  /// No description provided for @featureLogging.
  ///
  /// In en, this message translates to:
  /// **'Logging'**
  String get featureLogging;

  /// No description provided for @logClear.
  ///
  /// In en, this message translates to:
  /// **'Clear logs'**
  String get logClear;

  /// No description provided for @logExport.
  ///
  /// In en, this message translates to:
  /// **'Export logs'**
  String get logExport;

  /// No description provided for @logClearConfirm.
  ///
  /// In en, this message translates to:
  /// **'Clear all log records?'**
  String get logClearConfirm;

  /// No description provided for @logClearAction.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get logClearAction;

  /// No description provided for @logCleared.
  ///
  /// In en, this message translates to:
  /// **'Logs cleared'**
  String get logCleared;

  /// No description provided for @logClearFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to clear logs'**
  String get logClearFailed;

  /// No description provided for @logNoFile.
  ///
  /// In en, this message translates to:
  /// **'No log file'**
  String get logNoFile;

  /// No description provided for @restoreInProgress.
  ///
  /// In en, this message translates to:
  /// **'Restoring…'**
  String get restoreInProgress;

  /// No description provided for @restoreDone.
  ///
  /// In en, this message translates to:
  /// **'Data restored. The app will exit, please reopen it.'**
  String get restoreDone;

  /// No description provided for @restoreWriteFailed.
  ///
  /// In en, this message translates to:
  /// **'Restore failed. Restarting the app is recommended'**
  String get restoreWriteFailed;

  /// No description provided for @restoreNotBackup.
  ///
  /// In en, this message translates to:
  /// **'Not a valid NovaPlay backup file'**
  String get restoreNotBackup;

  /// No description provided for @restoreFileFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to restore the file: {error}'**
  String restoreFileFailed(String error);

  /// No description provided for @backupRestoreSheetDescription.
  ///
  /// In en, this message translates to:
  /// **'Choose items to restore. Local data of the same names will be overwritten by the backup.'**
  String get backupRestoreSheetDescription;

  /// No description provided for @backupCreatedAt.
  ///
  /// In en, this message translates to:
  /// **'Backup time: {time}'**
  String backupCreatedAt(String time);

  /// No description provided for @backupSourceVersion.
  ///
  /// In en, this message translates to:
  /// **'Source version: v{version} ({platform})'**
  String backupSourceVersion(String version, String platform);

  /// No description provided for @restoreConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirm restore'**
  String get restoreConfirmTitle;

  /// No description provided for @restoreConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'Selected data will be overwritten by the backup (extra local records will be lost). The app will then exit and needs to be reopened.'**
  String get restoreConfirmBody;

  /// No description provided for @exportDoneTitle.
  ///
  /// In en, this message translates to:
  /// **'Export complete'**
  String get exportDoneTitle;

  /// No description provided for @exportSavedAs.
  ///
  /// In en, this message translates to:
  /// **'Backup file saved at: {name}'**
  String exportSavedAs(String name);

  /// No description provided for @exportShareWarning.
  ///
  /// In en, this message translates to:
  /// **'The backup may contain sensitive info such as accounts and passwords. Share with care.'**
  String get exportShareWarning;

  /// No description provided for @share.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get share;

  /// No description provided for @exporting.
  ///
  /// In en, this message translates to:
  /// **'Exporting…'**
  String get exporting;

  /// No description provided for @exportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed, please try again'**
  String get exportFailed;

  /// No description provided for @shareFailed.
  ///
  /// In en, this message translates to:
  /// **'Share failed'**
  String get shareFailed;

  /// No description provided for @reload.
  ///
  /// In en, this message translates to:
  /// **'Reload'**
  String get reload;

  /// No description provided for @catpawTimeoutError.
  ///
  /// In en, this message translates to:
  /// **'Timed out connecting to the catpaw service, please try again later'**
  String get catpawTimeoutError;

  /// No description provided for @catpawUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Cannot reach the catpaw service, please make sure the local service is running'**
  String get catpawUnreachable;

  /// No description provided for @catpawBadCertificate.
  ///
  /// In en, this message translates to:
  /// **'The catpaw service certificate failed verification'**
  String get catpawBadCertificate;

  /// No description provided for @httpError.
  ///
  /// In en, this message translates to:
  /// **'HTTP {code}: {message}'**
  String httpError(int code, String message);

  /// No description provided for @playerLongPressSpeedAdjust.
  ///
  /// In en, this message translates to:
  /// **'Slide to adjust the long-press speed'**
  String get playerLongPressSpeedAdjust;

  /// No description provided for @playerLongPressSpeedAdjustSub.
  ///
  /// In en, this message translates to:
  /// **'Off: a long press always uses the fixed speed'**
  String get playerLongPressSpeedAdjustSub;

  /// No description provided for @playerMdkNote.
  ///
  /// In en, this message translates to:
  /// **'MDK ships with the arm64-v8a build only; elsewhere the player falls back to Exo and says why.'**
  String get playerMdkNote;

  /// No description provided for @playerIosAvplayerNote.
  ///
  /// In en, this message translates to:
  /// **'AVPlayer uses Apple VideoToolbox hardware decoding with native iOS Picture-in-Picture, AirPlay video routing, and low power draw (best for HLS / MP4).'**
  String get playerIosAvplayerNote;

  /// No description provided for @playerIosMpvNote.
  ///
  /// In en, this message translates to:
  /// **'MPV uses libmpv + FFmpeg + Metal/MoltenVK (gpu-next) with VideoToolbox hardware decoding, Dolby Vision / HDR tone mapping, MKV, and full ASS subtitles, without iOS system Picture-in-Picture.'**
  String get playerIosMpvNote;

  /// No description provided for @playerIosVlcNote.
  ///
  /// In en, this message translates to:
  /// **'VLC uses FFmpeg / libvlc for MKV, FLV, AVI, embedded ASS subtitles, and HW/SW decode switching, without iOS system Picture-in-Picture.'**
  String get playerIosVlcNote;

  /// No description provided for @playerHwDecodeIosAvSub.
  ///
  /// In en, this message translates to:
  /// **'AVPlayer always uses VideoToolbox hardware decoding; this toggle applies to the MPV and VLC kernels'**
  String get playerHwDecodeIosAvSub;

  /// No description provided for @playerAutoPipIosVlcSub.
  ///
  /// In en, this message translates to:
  /// **'iOS system Picture-in-Picture is available only with the AVPlayer kernel'**
  String get playerAutoPipIosVlcSub;

  /// No description provided for @playerSubtitleFontHintIos.
  ///
  /// In en, this message translates to:
  /// **'iOS system font family (e.g. PingFang SC)'**
  String get playerSubtitleFontHintIos;

  /// No description provided for @playerSubtitleNoteIos.
  ///
  /// In en, this message translates to:
  /// **'Supports embedded subtitle tracks and external SRT, WebVTT, and ASS/SSA (importable from Files or URL inside the player).'**
  String get playerSubtitleNoteIos;

  /// No description provided for @playerReloadNote.
  ///
  /// In en, this message translates to:
  /// **'Changing the kernel or hardware acceleration inside the player reloads the video at the current position.'**
  String get playerReloadNote;

  /// No description provided for @searchSiteManager.
  ///
  /// In en, this message translates to:
  /// **'Search sites'**
  String get searchSiteManager;

  /// No description provided for @searchSwitchLayout.
  ///
  /// In en, this message translates to:
  /// **'Switch layout'**
  String get searchSwitchLayout;

  /// No description provided for @searchLayoutList.
  ///
  /// In en, this message translates to:
  /// **'List'**
  String get searchLayoutList;

  /// No description provided for @searchLayoutTop.
  ///
  /// In en, this message translates to:
  /// **'Sites on top'**
  String get searchLayoutTop;

  /// No description provided for @searchLayoutLeft.
  ///
  /// In en, this message translates to:
  /// **'Sites on the left'**
  String get searchLayoutLeft;

  /// No description provided for @searchHistory.
  ///
  /// In en, this message translates to:
  /// **'Search history'**
  String get searchHistory;

  /// No description provided for @searchHistoryClear.
  ///
  /// In en, this message translates to:
  /// **'Clear search history'**
  String get searchHistoryClear;

  /// No description provided for @searchHistoryClearConfirm.
  ///
  /// In en, this message translates to:
  /// **'Clear all search history?'**
  String get searchHistoryClearConfirm;

  /// No description provided for @searchSearching.
  ///
  /// In en, this message translates to:
  /// **'Searching…'**
  String get searchSearching;

  /// No description provided for @searchFailed.
  ///
  /// In en, this message translates to:
  /// **'Search failed: {error}'**
  String searchFailed(String error);

  /// No description provided for @searchTwoColumns.
  ///
  /// In en, this message translates to:
  /// **'Two columns'**
  String get searchTwoColumns;

  /// No description provided for @searchOneColumn.
  ///
  /// In en, this message translates to:
  /// **'One column'**
  String get searchOneColumn;

  /// No description provided for @searchNoSites.
  ///
  /// In en, this message translates to:
  /// **'No sites yet. Add a subscription first'**
  String get searchNoSites;

  /// No description provided for @searchSiteTab.
  ///
  /// In en, this message translates to:
  /// **'{site} ({count})'**
  String searchSiteTab(String site, int count);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
