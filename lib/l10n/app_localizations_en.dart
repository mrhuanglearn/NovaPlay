// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'NovaPlay';

  @override
  String get tabHome => 'Home';

  @override
  String get tabLive => 'Live';

  @override
  String get tabCalendar => 'Calendar';

  @override
  String get tabLibrary => 'Library';

  @override
  String get tabSettings => 'Settings';

  @override
  String get pressBackAgainToExit => 'Press back again to exit';

  @override
  String get loadFailed => 'Failed to load';

  @override
  String get retry => 'Retry';

  @override
  String get paste => 'Paste';

  @override
  String get save => 'Save';

  @override
  String get cancel => 'Cancel';

  @override
  String get ok => 'OK';

  @override
  String get add => 'Add';

  @override
  String get delete => 'Delete';

  @override
  String get edit => 'Edit';

  @override
  String get search => 'Search';

  @override
  String get all => 'All';

  @override
  String get goToSettings => 'Go to settings';

  @override
  String get noData => 'No data';

  @override
  String get nothingHere => 'Nothing here yet';

  @override
  String get settingsGroupData => 'Data';

  @override
  String get settingsGroupPreferences => 'Preferences';

  @override
  String get settingsGroupTools => 'Tools';

  @override
  String get settingsSubscriptions => 'Subscriptions';

  @override
  String get settingsSubscriptionsSub => 'Manage sources and auto-update';

  @override
  String get settingsLive => 'Live';

  @override
  String get settingsLiveSub =>
      'Live sources, global EPG and hidden categories';

  @override
  String get settingsDanmu => 'Danmaku service';

  @override
  String get settingsDanmuSub => 'Danmaku API address and access token';

  @override
  String get settingsMediaServer => 'Media servers';

  @override
  String get settingsMediaServerSub =>
      'Emby and Jellyfin accounts, browse libraries';

  @override
  String get settingsTmdb => 'TMDB';

  @override
  String get settingsTmdbSub => 'API key and scraping proxy';

  @override
  String get settingsWebdav => 'WebDAV sync';

  @override
  String get settingsWebdavSub =>
      'Sync data across devices (choose what to sync)';

  @override
  String get settingsBackup => 'Backup & restore';

  @override
  String get settingsBackupSub =>
      'Pack data as a zip backup or share it; restore from a backup';

  @override
  String get settingsPlayer => 'Player';

  @override
  String get settingsPlayerSub => 'Kernel, speed, subtitles and display';

  @override
  String get settingsSniffer => 'Web video sniffer';

  @override
  String get settingsSnifferSub => 'Find videos and streams in web pages';

  @override
  String get secondsShort => 's';

  @override
  String get saved => 'Saved';

  @override
  String get serverAddress => 'Server address';

  @override
  String get port => 'Port';

  @override
  String get tokenOptional => 'Token (optional)';

  @override
  String get testConnection => 'Test connection';

  @override
  String get playerGroupPlayback => 'Playback';

  @override
  String get playerKernel => 'Player kernel';

  @override
  String get playerHwDecode => 'Hardware acceleration';

  @override
  String get playerFit => 'Picture fill';

  @override
  String get playerFitFit => 'Original ratio';

  @override
  String get playerFitFill => 'Stretch to fill';

  @override
  String get playerFitZoom => 'Crop to fill';

  @override
  String get playerDefaultSpeed => 'Default speed';

  @override
  String get playerLongPressSpeed => 'Long-press speed';

  @override
  String get playerDoubleTapSeek => 'Seek step (seconds)';

  @override
  String get playerMpvNote =>
      'MPV needs libmpv.so in the APK. Without it the player page falls back to Exo and says why.';

  @override
  String get playerGroupSubtitles => 'Subtitles & audio';

  @override
  String get playerSubtitleLang => 'Preferred subtitle language';

  @override
  String get playerSubtitleFont => 'Subtitle font';

  @override
  String get playerSubtitleFontHint =>
      'A system font name, or a file name in the fonts folder';

  @override
  String get playerFontsDir => 'Fonts folder (optional)';

  @override
  String get playerAudioLang => 'Preferred audio language';

  @override
  String get playerSubtitleNote =>
      'SRT, WebVTT, TTML and basic ASS/SSA are supported. ASS is drawn by Exo\'s simple parser, not libass.';

  @override
  String get playerGroupBehaviour => 'Behaviour';

  @override
  String get playerPreferLandscape => 'Prefer landscape';

  @override
  String get playerAutoPip => 'Picture-in-picture in background';

  @override
  String get playerPauseInBackground => 'Pause in background';

  @override
  String get playerSkipNotice => 'Skip notice';

  @override
  String get playerEpisodeSwitchNotice => 'Episode switch notice';

  @override
  String get playerHaptics => 'Haptic feedback';

  @override
  String get playerGroupOverlay => 'On-screen info';

  @override
  String get playerShowNetSpeed => 'Always show network speed';

  @override
  String get playerShowStats => 'Show frame rate and codec';

  @override
  String get playerShowTotalDuration =>
      'Show total duration on the progress bar';

  @override
  String get playerHideSeekButtons => 'Hide centre seek buttons';

  @override
  String get danmuEnable => 'Enable danmaku';

  @override
  String get danmuSource => 'Danmaku service source';

  @override
  String get danmuModeOff => 'Off';

  @override
  String get danmuModeBuiltin => 'Local';

  @override
  String get danmuModeSubscription => 'Subscription';

  @override
  String get danmuModeRemote => 'Remote';

  @override
  String get danmuModeOffNote => 'No danmaku server is used.';

  @override
  String get danmuModeBuiltinNote =>
      'Runs a danmu_api script you supply inside the Node runtime.';

  @override
  String get danmuModeSubscriptionNote =>
      'Uses port 9321 of the active subscription.';

  @override
  String get danmuModeRemoteNote => 'Your own danmu_api server.';

  @override
  String get danmuScriptUrl => 'danmu_api script URL (server.cjs)';

  @override
  String get danmuDownloadScript => 'Download / update script';

  @override
  String danmuScriptDownloaded(String md5) {
    return 'Script downloaded (md5 $md5)';
  }

  @override
  String get danmuNotReachable => 'Not reachable or not configured';

  @override
  String danmuReachable(int count) {
    return 'Reachable ($count results for \"a\")';
  }

  @override
  String get danmuGroupAppearance => 'Appearance';

  @override
  String get danmuOpacity => 'Opacity';

  @override
  String get danmuFontSize => 'Font size';

  @override
  String get danmuScrollSpeed => 'Scroll speed';

  @override
  String get danmuArea => 'Display area';

  @override
  String get danmuDelay => 'Delay';

  @override
  String get danmuTop => 'Top comments';

  @override
  String get danmuBottom => 'Bottom comments';

  @override
  String get danmuBlockedWords => 'Blocked words';

  @override
  String get danmuBlockedWordsHint => 'One per line';

  @override
  String get connectionOk => 'Connection OK';

  @override
  String get advanced => 'Advanced';

  @override
  String get language => 'Language';

  @override
  String get password => 'Password';

  @override
  String get restore => 'Restore';

  @override
  String get copied => 'Copied';

  @override
  String get clipboardEmpty => 'Clipboard is empty';

  @override
  String get tmdbConnectionFailed => 'Connection failed (check key / address)';

  @override
  String get tmdbConnectTitle => 'Connect TMDB';

  @override
  String get tmdbConnectDescription =>
      'Once connected, posters, overviews and cast are matched automatically and the calendar stays up to date';

  @override
  String get tmdbEnable => 'Enable TMDB';

  @override
  String get tmdbEnableSub =>
      'Posters, episode names and the tracking calendar';

  @override
  String get tmdbKeyHint =>
      'TMDB API key (v3) or read access token (v4), detected automatically';

  @override
  String get tmdbApiBase => 'API address (empty = official)';

  @override
  String get tmdbImageBase => 'Image address (empty = official)';

  @override
  String get tmdbMatchWait => 'Detail page match wait (seconds)';

  @override
  String get tmdbKeyStorageNote =>
      'The key is stored in plain text in tmdb_settings.json and is included in WebDAV sync and backups.';

  @override
  String get webdavAccount => 'Account name';

  @override
  String get webdavSubFolder => 'Sub folder (optional)';

  @override
  String get webdavSubFolderHint =>
      'Isolates data when sharing one WebDAV; leave empty to use the root';

  @override
  String get webdavSyncNow => 'Sync now';

  @override
  String webdavSyncResult(int pushed, int pulled) {
    return 'Uploaded $pushed, downloaded $pulled document(s)';
  }

  @override
  String get webdavNote =>
      'Favorites, history, progress, TMDB matches and key, tracking, player and live settings are synced. The password and the TMDB key are stored in plain text.';

  @override
  String get webdavNotConfigured => 'Configure WebDAV first';

  @override
  String get backupGroupExport => 'Export backup';

  @override
  String get backupGroupRestore => 'Restore from backup';

  @override
  String get backupShareFile => 'Share backup file';

  @override
  String get backupShareFileSub => 'One JSON file with every synced document';

  @override
  String get backupShareText => 'NovaPlay backup';

  @override
  String get backupCopy => 'Copy backup to clipboard';

  @override
  String get backupRestoreClipboard => 'Restore from clipboard';

  @override
  String get backupRestoreWebdav => 'Restore from WebDAV';

  @override
  String get backupRestoreWebdavSub =>
      'Takes the remote copy of every document';

  @override
  String backupRestored(int count) {
    return 'Restored $count document(s)';
  }

  @override
  String get backupSensitiveNote =>
      'Backups may contain accounts, passwords and keys; be careful when sharing them.';

  @override
  String get name => 'Name';

  @override
  String get subscriptions => 'Subscriptions';

  @override
  String get subscriptionAdd => 'Add subscription';

  @override
  String get subscriptionsEmptyTitle => 'No subscriptions yet';

  @override
  String get subscriptionsEmptySubtitle =>
      'Add a subscription to start aggregating your content';

  @override
  String get subscriptionDelete => 'Delete subscription';

  @override
  String subscriptionDeleteConfirm(String name) {
    return 'Delete \"$name\"?';
  }

  @override
  String get subscriptionKindNetwork => 'Network';

  @override
  String get subscriptionKindCloud => 'Cloud';

  @override
  String get subscriptionNetworkHint =>
      'Add a data source to aggregate content';

  @override
  String get subscriptionCloudHint =>
      'Connect directly to a catpaw service running elsewhere, no script download';

  @override
  String get subscriptionSourceUrl => 'Data source URL';

  @override
  String get subscriptionCloudAddress => 'Cloud service address';

  @override
  String get subscriptionNameHint =>
      'Leave empty to derive it from the address';

  @override
  String get subscriptionDanmuToken => 'Danmaku service token (optional)';

  @override
  String get subscriptionDanmuTokenHint =>
      'Path prefix of the subscription\'s own danmaku server';

  @override
  String get subscriptionLock => 'Lock';

  @override
  String get subscriptionLockSub =>
      'Locked subscriptions are visible only after the lock password is verified';

  @override
  String get subscriptionUrlRequired => 'Enter the data source URL';

  @override
  String get filter => 'Filter';

  @override
  String get homeCatpawUnavailable => 'Cannot connect to the catpaw service';

  @override
  String get libraryHistory => 'History';

  @override
  String get libraryFavorites => 'Favorites';

  @override
  String get libraryDownloads => 'Downloads';

  @override
  String get historyEmptySubtitle =>
      'Nothing watched yet, go find something to watch';

  @override
  String get favoritesEmptyTitle => 'No favorites yet';

  @override
  String get favoritesEmptySubtitle => 'Find videos you like and favorite them';

  @override
  String get downloadsEmptyTitle => 'No downloads';

  @override
  String get downloadsEmptySubtitle => 'No download tasks';

  @override
  String get downloadsOtherGroup => 'Other';

  @override
  String downloadsDoneCount(int done, int total) {
    return '$done/$total done';
  }

  @override
  String get downloadQueued => 'Queued';

  @override
  String get downloadRunning => 'Downloading';

  @override
  String get downloadPaused => 'Paused';

  @override
  String get downloadDone => 'Done';

  @override
  String get downloadFailed => 'Failed';

  @override
  String get downloadPause => 'Pause';

  @override
  String get downloadResume => 'Resume';

  @override
  String get noResults => 'No results';

  @override
  String get mediaSeries => 'Series';

  @override
  String get mediaMovie => 'Movie';

  @override
  String get tmdbNotEnabledError =>
      'Enable TMDB and enter an API key in Settings first';

  @override
  String get tmdbSearchHint => 'Search TMDB';

  @override
  String get tmdbSearchPrompt => 'Type a title and press search';

  @override
  String get trackingSeason => 'Season';

  @override
  String get trackingSeasonNumber => 'Season number';

  @override
  String get trackingManage => 'Tracking';

  @override
  String get trackingAdd => 'Add series';

  @override
  String get trackingAutoSync => 'Sync favorites to the calendar';

  @override
  String get trackingAutoSyncSub =>
      'Favorited series that TMDB knows join the calendar';

  @override
  String get trackingEmpty => 'Nothing tracked yet';

  @override
  String get trackingFollowed => 'Following';

  @override
  String trackingShowSubtitle(int season, int watched) {
    return 'Season $season · watched $watched';
  }

  @override
  String get calendarTmdbDisabled =>
      'TMDB is off, so the calendar cannot be updated';

  @override
  String get calendarThisWeek => 'This week';

  @override
  String get calendarNothingThisWeek => 'Nothing airs this week';

  @override
  String calendarEpisode(int number, String name) {
    return 'E$number $name';
  }

  @override
  String get markedWatched => 'Marked watched';

  @override
  String get markedUnwatched => 'Marked unwatched';

  @override
  String get liveSearchChannels => 'Search channels';

  @override
  String get liveSettings => 'Live settings';

  @override
  String get liveEmptyTitle => 'No live sources yet';

  @override
  String get liveEmptySubtitle => 'Add an M3U playlist to start watching';

  @override
  String get liveAddSource => 'Add live source';

  @override
  String get liveEditSource => 'Edit live source';

  @override
  String get liveNoChannels => 'No channels';

  @override
  String get liveSourcesGroup => 'Live sources';

  @override
  String get liveBlockedGroup => 'Blocked categories';

  @override
  String get liveBlockedCategories => 'Blocked categories';

  @override
  String get liveBlockedCategoriesSub =>
      'Channels of a blocked category are hidden';

  @override
  String get liveM3uUrl => 'M3U address';

  @override
  String get liveEpgUrl => 'XMLTV guide address (optional)';

  @override
  String get favorite => 'Favorite';

  @override
  String get notFound => 'Not found';

  @override
  String get downloadStarted => 'Download started';

  @override
  String get addedToCalendar => 'Added to the tracking calendar';

  @override
  String detailDirector(String name) {
    return 'Director: $name';
  }

  @override
  String detailCast(String names) {
    return 'Cast: $names';
  }

  @override
  String get detailMatchTmdb => 'Match TMDB';

  @override
  String get detailNoLines => 'No playable lines';

  @override
  String get detailLongPressToDownload =>
      'Long-press an episode to download it.';

  @override
  String get searchHint => 'Search videos…';

  @override
  String get searchPrompt => 'Type a keyword to search every site at once';

  @override
  String get userName => 'User name';

  @override
  String get signIn => 'Sign in';

  @override
  String signInFailed(String error) {
    return 'Sign-in failed: $error';
  }

  @override
  String get play => 'Play';

  @override
  String get embyAddServer => 'Add server';

  @override
  String get embyServerType => 'Type';

  @override
  String get embyEmptyTitle => 'No servers yet';

  @override
  String get embySearchLibrary => 'Search library';

  @override
  String get embyAccountNotFound => 'Account not found';

  @override
  String get embyContinueWatching => 'Continue watching';

  @override
  String get embyLatest => 'Latest';

  @override
  String embySeason(int season) {
    return 'Season $season';
  }

  @override
  String get embyInProgress => 'In progress';

  @override
  String get snifferNothingYet =>
      'Nothing sniffed yet. Start playing a video on the page.';

  @override
  String get snifferPrompt => 'Enter a page address to look for videos';

  @override
  String get webAddressHint => 'Address';

  @override
  String get configChecksumMismatchTitle => 'Config checksum mismatch';

  @override
  String get configChecksumMismatchBody =>
      'The md5 of index.config.js does not match its checksum file (the author may not have updated the .md5). Use this config anyway?';

  @override
  String get done => 'Done';

  @override
  String get selectAll => 'Select all';

  @override
  String get deselectAll => 'Deselect all';

  @override
  String selectedCount(int count) {
    return '$count selected';
  }

  @override
  String get subscriptionKindLocal => 'Local';

  @override
  String get subscriptionLocalHint =>
      'Pick a local zip archive as the subscription source. It must contain both index.js and index.config.js.';

  @override
  String get subscriptionLocalArchive => 'Local archive';

  @override
  String get subscriptionPickArchive => 'Choose archive';

  @override
  String get subscriptionChipNetwork => 'URL';

  @override
  String get subscriptionChipCloud => 'Cloud service';

  @override
  String get subscriptionChipLocal => 'Local zip';

  @override
  String get subscriptionAutoUpdate => 'Auto update';

  @override
  String get subscriptionAutoUpdateSub => 'Sync the latest content on launch';

  @override
  String get subscriptionLockSingle =>
      'Locking needs more than one subscription';

  @override
  String get subscriptionInstallUntrusted => 'Install untrusted subscription';

  @override
  String get subscriptionConnectCloud => 'Connect cloud service';

  @override
  String get subscriptionCantAdd => 'Can\'t add?';

  @override
  String get notice => 'Notice';

  @override
  String get subscriptionCantAddHelp =>
      'Network environments differ. If you can\'t connect or the download fails, try [turn on your proxy with the proxy tool\'s TUN mode] or [turn the proxy off], then try again.';

  @override
  String get added => 'Added';

  @override
  String get subscriptionDuplicate =>
      'A subscription with this URL already exists';

  @override
  String subscriptionDownloadFailed(String error) {
    return 'Failed to download the subscription: $error';
  }

  @override
  String subscriptionZipFailed(String error) {
    return 'Failed to install the local archive: $error';
  }

  @override
  String get subscriptionZipRequired => 'Choose a zip archive first';

  @override
  String get subscriptionLastUpdated => 'Last updated';

  @override
  String subscriptionLastUpdatedAt(String when) {
    return 'Updated $when';
  }

  @override
  String get timeJustNow => 'just now';

  @override
  String timeMinutesAgo(int n) {
    return '$n min ago';
  }

  @override
  String timeHoursAgo(int n) {
    return '$n h ago';
  }

  @override
  String timeDaysAgo(int n) {
    return '$n d ago';
  }

  @override
  String get subscriptionActivate => 'Activate';

  @override
  String get subscriptionActive => 'Active';

  @override
  String subscriptionSwitchedTo(String name) {
    return 'Switched to $name';
  }

  @override
  String get subscriptionCannotDeleteActive =>
      'The active subscription can\'t be deleted. Switch to another source first.';

  @override
  String subscriptionDeleteSelectedConfirm(int count) {
    return 'Delete the $count selected subscriptions? This cannot be undone.';
  }

  @override
  String subscriptionDeleteOneConfirm(String name) {
    return 'Delete \"$name\"? This cannot be undone.';
  }

  @override
  String subscriptionUpToDate(String name) {
    return '\"$name\" is up to date';
  }

  @override
  String get subscriptionUpdatedOne => 'Updated to the latest version';

  @override
  String subscriptionUpdatedCount(int count) {
    return 'Updated $count subscriptions';
  }

  @override
  String get subscriptionAllUpToDate => 'All subscriptions are up to date';

  @override
  String subscriptionCheckFailed(String error) {
    return 'Update check failed ($error)';
  }

  @override
  String get subscriptionChecking => 'Checking for subscription updates…';

  @override
  String get subscriptionEdit => 'Edit subscription';

  @override
  String get subscriptionFingerprint => 'Content fingerprint';

  @override
  String get subscriptionReplaceZip => 'Replace local script';

  @override
  String get subscriptionReplaceZipSub =>
      'Choose a zip archive again to overwrite the current local source';

  @override
  String get subscriptionNotFound => 'Subscription not found';

  @override
  String get homeSwitchSite => 'Switch site';

  @override
  String get homeBlockCategories => 'Block categories';

  @override
  String get homeHideFilters => 'Hide filters';

  @override
  String get homeShowFilters => 'Show filters';

  @override
  String get homeSwitchLayout => 'Switch layout';

  @override
  String get homeNoBlockableCategories =>
      'This site has no categories left to block';

  @override
  String get homePushNotSupported =>
      'This subscription doesn\'t support push parsing';

  @override
  String get homePushTitle => 'Push to parse';

  @override
  String get homePushHint => 'Paste a share link…';

  @override
  String get homePushDescription =>
      'Paste a cloud-drive share link or a direct video link to resolve its play lines';

  @override
  String get homeNoSites => 'No sites available. Add a subscription first.';

  @override
  String get detailPlayNow => 'Play';

  @override
  String get detailEpisodes => 'Episodes';

  @override
  String get detailIntro => 'Synopsis';

  @override
  String detailEpisodeSheetSub(String line, int count) {
    return '$line · $count episodes';
  }

  @override
  String get detailLocateCurrent => 'Go to current episode';

  @override
  String get detailReverseOrder => 'Reverse order';

  @override
  String get searchEmptyTitle => 'Search videos';

  @override
  String get mediaAccountsTitle => 'Media server accounts';

  @override
  String get mediaEmptySubtitle => 'Add an account to browse your Emby library';

  @override
  String get mediaAddAccount => 'Add account';

  @override
  String get mediaServerType => 'Server type';

  @override
  String get mediaAutoDetect => 'Auto-detect';

  @override
  String get mediaAddressHint => 'e.g. http://192.168.1.10:8096';

  @override
  String get mediaPasswordHint => 'Optional';

  @override
  String get mediaSignInAndSave => 'Sign in and save';

  @override
  String get mediaAccountExists => 'This account already exists';

  @override
  String get mediaSignedIn => 'Signed in';

  @override
  String get mediaAddressRequired => 'Enter the server address';

  @override
  String mediaDeleteConfirm(String name) {
    return 'Delete “$name”? You will need to sign in again to use this server.';
  }

  @override
  String get tmdbConnect => 'Connect';

  @override
  String get tmdbGetKey => 'Get an API key';

  @override
  String get tmdbConnected => 'Connected to TMDB';

  @override
  String get tmdbDisconnect => 'Disconnect';

  @override
  String get tmdbDisconnectTitle => 'Disconnect TMDB?';

  @override
  String get tmdbDisconnectBody =>
      'The API key is cleared and TMDB is turned off; the proxy settings are kept.';

  @override
  String get tmdbProxyGroup => 'Proxy and advanced';

  @override
  String get webdavEmptyTitle => 'WebDAV sync is not set up';

  @override
  String get webdavEmptySubtitle =>
      'Add a server address, account and password to sync your data between devices';

  @override
  String get webdavAddConfig => 'Add configuration';

  @override
  String get webdavConfigTitle => 'WebDAV configuration';

  @override
  String get webdavEditConfig => 'Edit configuration';

  @override
  String get webdavIsolation => 'Isolation name';

  @override
  String get webdavIsolationHint =>
      'Keeps data apart when several people share one WebDAV; empty = root folder';

  @override
  String get webdavServiceAddress => 'Service address';

  @override
  String get webdavServiceAddressHint => 'e.g. https://dav.jianguoyun.com/dav/';

  @override
  String get webdavAccountLabel => 'Account';

  @override
  String get webdavAccountHint => 'WebDAV user name';

  @override
  String get webdavPasswordHint => 'App password';

  @override
  String get webdavFillRequired =>
      'Fill in the service address, account and password first';

  @override
  String get webdavConnectFailed => 'WebDAV connection failed';

  @override
  String get webdavAuthFailed =>
      'WebDAV authentication failed, check the account and password';

  @override
  String get webdavEnableSync => 'Enable sync';

  @override
  String get webdavEnableSyncSub =>
      'Sync the selected data when the app starts';

  @override
  String get webdavSyncing => 'Syncing…';

  @override
  String get webdavNeverSynced => 'Not synced yet';

  @override
  String webdavLastSync(String time) {
    return 'Last sync $time';
  }

  @override
  String get webdavSyncDone => 'Sync complete';

  @override
  String webdavSyncFailed(String error) {
    return 'WebDAV sync failed: $error';
  }

  @override
  String get webdavNoTypes => 'No data type selected';

  @override
  String get webdavTypesGroup => 'What to sync';

  @override
  String get webdavTypeFavorites => 'Favorites';

  @override
  String get webdavTypeFavoritesSub =>
      'Favorites and the calendar auto-sync switch';

  @override
  String get webdavTypeHistory => 'History and progress';

  @override
  String get webdavTypeHistorySub =>
      'Watch history, playback positions and last episodes';

  @override
  String get webdavTypeTracking => 'Tracked shows';

  @override
  String get webdavTypeTrackingSub => 'Shows on the calendar';

  @override
  String get webdavTypeTmdb => 'TMDB';

  @override
  String get webdavTypeTmdbSub =>
      'TMDB switch, API key and proxy addresses (replaced as a group) plus match records; the API key is stored in plain text on the WebDAV server';

  @override
  String get webdavTypePlayer => 'Player settings';

  @override
  String get webdavTypePlayerSub => 'Player settings and intro/outro records';

  @override
  String get webdavTypeLive => 'Live TV';

  @override
  String get webdavTypeLiveSub =>
      'Live sources, global EPG and hidden categories';

  @override
  String get liveGlobalEpg => 'Global EPG URL';

  @override
  String get liveGlobalEpgHint =>
      'Used when a source has no EPG of its own, e.g. https://example.com/epg.xml.gz';

  @override
  String get liveEpgSaved => 'EPG URL saved';

  @override
  String get liveSourceUrl => 'Source URL';

  @override
  String get liveNameHint => 'e.g. My live TV';

  @override
  String get liveM3uOnly => 'Only M3U playlists are supported';

  @override
  String get liveAutoRefresh => 'Auto refresh';

  @override
  String get liveRefreshOff => 'Off';

  @override
  String get liveRefreshAlways => 'Every time';

  @override
  String get liveRefresh24h => '24 hours';

  @override
  String get liveVerifyAndSave => 'Verify and save';

  @override
  String get liveSourceSaved => 'Live source saved';

  @override
  String liveSourceSaveFailed(String error) {
    return 'Could not save the live source: $error';
  }

  @override
  String get liveSourceExists =>
      'A live source with this address already exists';

  @override
  String liveDeleteConfirm(String name) {
    return 'Delete the live source “$name”?';
  }

  @override
  String get liveSourceDeleted => 'Live source deleted';

  @override
  String get liveBlockedEmpty => 'No hidden categories';

  @override
  String get liveBlockPick => 'Hide a category';

  @override
  String get liveNothingToBlock => 'No category left to hide';

  @override
  String liveCategoryBlocked(String name) {
    return 'Hid “$name”';
  }

  @override
  String liveCategoryUnblocked(String name) {
    return 'Showing “$name” again';
  }

  @override
  String get liveUserAgentHint => 'Custom User-Agent';

  @override
  String get danmuStatus => 'Status';

  @override
  String get danmuStopped => 'Stopped';

  @override
  String danmuRunning(String port) {
    return 'Running: $port';
  }

  @override
  String get danmuNoService => 'No danmaku service yet';

  @override
  String get danmuNoServiceSub =>
      'Add a network source or a local script below';

  @override
  String get danmuOpenWeb => 'Open web page';

  @override
  String get danmuRestart => 'Restart service';

  @override
  String get danmuStop => 'Stop service';

  @override
  String get danmuNotReady => 'The service is not ready, cannot open the page';

  @override
  String get danmuNetworkSource => 'Network source';

  @override
  String get danmuLocalScriptTab => 'Local script';

  @override
  String get danmuSourceUrl => 'Source URL (.cjs.md5)';

  @override
  String get danmuDownload => 'Download script';

  @override
  String get danmuLoadLocal => 'Load local script';

  @override
  String get danmuReplaceLocal => 'Replace local script';

  @override
  String get danmuLocalLoaded => 'Local script loaded';

  @override
  String danmuLocalOnlyCjs(String name) {
    return 'Only .cjs/.js files (got: $name)';
  }

  @override
  String get danmuRemoteHint => 'http://ip:9321 or http://ip:9321/TOKEN';

  @override
  String get danmuShowTop => 'Show top danmaku';

  @override
  String get danmuShowBottom => 'Show bottom danmaku';

  @override
  String get danmuShowPositionSub => 'When off, these scroll instead';

  @override
  String get danmuColor => 'Danmaku colour';

  @override
  String get danmuColorOriginal => 'Own colours';

  @override
  String get danmuColorWhite => 'White';

  @override
  String get danmuColorRandom => 'Random (solid)';

  @override
  String get danmuLineHeight => 'Line spacing';

  @override
  String get danmuStroke => 'Outline';

  @override
  String get danmuBlockedWordsTitle => 'Blocked words';

  @override
  String get danmuBlockedWordsEmpty =>
      'No blocked words; danmaku containing one are filtered out';

  @override
  String get danmuBlockedWordAdd => 'Add blocked word';

  @override
  String get playerGroupDecode => 'Decoding';

  @override
  String get playerGroupPicture => 'Picture and engine';

  @override
  String get playerHwDecodeSub =>
      'Off: software decoding (more compatible, uses more power)';

  @override
  String get playerShowTotalDurationSub => 'Off: show the remaining time';

  @override
  String get playerAutoPipSub =>
      'Keep playing in picture-in-picture when you leave the app';

  @override
  String get playerSkipNoticeSub =>
      'Show a banner and a short notice when intros/outros are skipped';

  @override
  String get playerEpisodeSwitchNoticeSub =>
      'Show “Switching to episode x” when the episode changes';

  @override
  String get playerShowStatsSub => 'Costs some performance';

  @override
  String get playerShowNetSpeedSub =>
      'See the download speed without opening the info bar';

  @override
  String get backupExportItems => 'Choose data and export';

  @override
  String get backupExportItemsSub => 'Packed as a zip into Backups';

  @override
  String get backupRestoreFile => 'Restore from a backup file';

  @override
  String get backupRestoreFileSub =>
      'Overwrite data from a zip backup (older JSON backups work too)';

  @override
  String get backupSheetDescription =>
      'Tick the data to export. Subscriptions, settings and accounts may contain account names, passwords or tokens, written in plain text into the backup file.';

  @override
  String get backupSensitiveWarning =>
      'The selected data contains accounts, passwords or tokens, written in plain text into the backup file. Keep it safe and share it with care.';

  @override
  String get backupExportButton => 'Export';

  @override
  String get backupGroupUser => 'User data';

  @override
  String get backupGroupSubscriptions => 'Subscriptions and danmaku';

  @override
  String get backupGroupPreferences => 'Preferences';

  @override
  String get backupItemHistory => 'Watch history';

  @override
  String get backupItemFavorites => 'Favorites';

  @override
  String get backupItemProgress => 'Playback progress';

  @override
  String get backupItemLastEpisode => 'Last episodes';

  @override
  String get backupItemTmdbRefs => 'TMDB matches';

  @override
  String get backupItemHeadTail => 'Intros and outros';

  @override
  String get backupItemTracking => 'Tracked shows';

  @override
  String get backupItemDanmuRefs => 'Danmaku matches';

  @override
  String get backupItemLive => 'Live sources';

  @override
  String get backupItemSubscriptions => 'Subscription list';

  @override
  String get backupItemAppSettings => 'App settings (with danmaku service)';

  @override
  String get backupItemAccounts => 'Media server and WebDAV accounts';

  @override
  String get backupRestoreWebdavTitle => 'Restore from WebDAV';

  @override
  String get webSearchHint => 'Enter a URL or search words';

  @override
  String get webGo => 'Go';

  @override
  String get webClearList => 'Clear list';

  @override
  String get webOpenExternal => 'Open in external browser';

  @override
  String get webClearCookies => 'Clear web cookies';

  @override
  String get webCookiesCleared => 'WebView cookies cleared';

  @override
  String get webUaDefault => 'Default';

  @override
  String get webUaDesktop => 'Desktop Chrome';

  @override
  String get webUaCustom => 'Custom…';

  @override
  String get webReload => 'Reload';

  @override
  String get webSniffed => 'Found media';

  @override
  String get languageSystem => 'Follow system';

  @override
  String get languageZh => '简体中文';

  @override
  String get languageEn => 'English';

  @override
  String get settingsTheme => 'Theme';

  @override
  String get settingsThemeSub => 'Color, dark style, font size';

  @override
  String get themeCustomize => 'Appearance';

  @override
  String get themeModeLabel => 'Theme mode';

  @override
  String get themeAuto => 'Auto';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get themeDarkStyle => 'Dark background';

  @override
  String get themeDarkGray => 'Dark grey';

  @override
  String get themeDarkBlack => 'Pure black';

  @override
  String get themeFontSize => 'Font size';

  @override
  String get settingsFeatures => 'Features';

  @override
  String get settingsFeaturesSub => 'Behaviour and switches';

  @override
  String get catpawTimeout => 'catpaw service timeout';

  @override
  String get catpawTimeoutSub => 'How long to wait for catpaw data';

  @override
  String get catpawTimeoutField => 'Receive timeout (s)';

  @override
  String get settingsCleanup => 'Clean up data';

  @override
  String get settingsCleanupSub => 'Choose what to clear';

  @override
  String get cleanupDescription =>
      'Tick the items to clear, then tap the button below.';

  @override
  String get cleanupGroupCache => 'Cache';

  @override
  String get cleanupImages => 'Image cache';

  @override
  String get cleanupTemp => 'Temporary files';

  @override
  String get cleanupLivePlaylists => 'Live playlist cache';

  @override
  String get cleanupRun => 'Clear selected';

  @override
  String cleanupDone(int count) {
    return 'Cleared $count item(s)';
  }

  @override
  String cleanupFailed(String error) {
    return 'Could not clear: $error';
  }

  @override
  String get settingsHomeTabs => 'Home pages';

  @override
  String get settingsHomeTabsSub =>
      'Choose the pages on the bottom bar and their order';

  @override
  String get homeTabsEnabled => 'Enabled';

  @override
  String get homeTabsDisabled => 'Not enabled';

  @override
  String get homeTabsHint => 'Long-press and drag to reorder';

  @override
  String get homeTabsRequired => 'Required page, cannot be turned off';

  @override
  String get downloadsManage => 'Downloads';

  @override
  String get mediaManageAccounts => 'Manage accounts';

  @override
  String get lockPassword => 'Lock password';

  @override
  String get lockNotSet => 'Not set';

  @override
  String get lockSet => 'Set';

  @override
  String get lockEmpty => 'Empty password';

  @override
  String get lockStateNotSet => 'No lock password has been set';

  @override
  String get lockStateSet => 'A lock password is set';

  @override
  String get lockStateEmpty => 'The password is empty (no protection)';

  @override
  String get lockStepNew => 'Enter a new password';

  @override
  String get lockStepConfirm => 'Enter it again to confirm';

  @override
  String get lockStepOld => 'Verify the old password';

  @override
  String get lockTapHint => 'Tap the colour tiles to enter the password';

  @override
  String get lockTooShort => 'Enter at least one digit';

  @override
  String get lockMismatch => 'The two entries differ, please try again';

  @override
  String get lockWrongOld => 'Wrong old password';

  @override
  String get lockUpdated => 'Lock password updated';

  @override
  String get lockCleared => 'Lock password cleared';

  @override
  String get lockSetEmpty => 'Set to an empty password';

  @override
  String get lockVerifyTitle => 'Verify lock password';

  @override
  String get lockFirstTitle => 'First lock';

  @override
  String get lockFirstBody =>
      'Set a lock password? Without one an empty password is used (no protection).';

  @override
  String get lockSkip => 'Don\'t set';

  @override
  String get lockClear => 'Clear';

  @override
  String get lockNext => 'Next';

  @override
  String get lockConfirm => 'Confirm';

  @override
  String get lockUnlock => 'Unlock';

  @override
  String get lockHiddenSubscriptions => 'Locked subscriptions are hidden';

  @override
  String get lockUnlockSubscriptions => 'Unlock subscriptions';

  @override
  String get lockRelock => 'Lock again';

  @override
  String get lockHomeTitle => 'Subscription locked';

  @override
  String get lockHomeSubtitle =>
      'The current subscription is locked; unlock it to view';

  @override
  String get lockBackspace => 'Delete';

  @override
  String get settingsReset => 'Reset app';

  @override
  String get settingsResetSub => 'Erase all data and restart';

  @override
  String get resetConfirmBody =>
      'All local data (subscriptions, history, favourites, settings, fonts, downloads, catpaw instance data and everything else) will be erased and the app restarted, like a factory reset. Exported backup files are kept. This cannot be undone. Continue?';

  @override
  String get resetInProgress => 'Resetting…';

  @override
  String get resetDone =>
      'All data has been erased. The app will now close; please open it again.';

  @override
  String get resetFailed => 'Reset failed, please try again';

  @override
  String get settingsGroupDeveloper => 'Developer';

  @override
  String get settingsCatpawDebug => 'catpaw Debug';

  @override
  String get settingsCatpawDebugSub =>
      'Start & manage catpaw instances, view logs';

  @override
  String get debugTitle => 'catpaw multi-instance';

  @override
  String get debugStartTitle => 'Start catpaw Runtime';

  @override
  String get debugStartSub =>
      'Start the embedded Node runtime to load and manage catpaw instances and generic services';

  @override
  String get debugDartPort => 'Dart callback port (empty=random)';

  @override
  String get debugStartNode => 'Start Node';

  @override
  String get debugNodeStarting => 'Node.js is starting…';

  @override
  String get debugNodeRunning => 'Node running';

  @override
  String get debugLastResult => 'Last result';

  @override
  String get debugCopyLast => 'Copy Last';

  @override
  String get debugCopiedLast => 'Copied Last';

  @override
  String get debugLog => 'Logs';

  @override
  String get debugNoLogs => 'No logs';

  @override
  String get debugCopyAllLogs => 'Copy all logs';

  @override
  String get debugClearLogs => 'Clear logs';

  @override
  String get debugLogsCleared => 'Logs cleared';

  @override
  String get debugTabServices => 'Generic service';

  @override
  String get debugLoadInstance => 'Load instance';

  @override
  String get debugInstanceName =>
      'Instance name (storage key, defaults to URL account)';

  @override
  String get debugPort => 'Port (empty=random)';

  @override
  String get debugForceRestart => 'Force restart if exists';

  @override
  String get debugNetAudit => 'Network audit (log outbound requests)';

  @override
  String get debugServiceLog => 'Service log (forward console)';

  @override
  String get debugLoadButton => 'Load catpaw instance';

  @override
  String get debugRunningInstances => 'Running instances';

  @override
  String get debugNoInstance => 'No instance';

  @override
  String get debugTest => 'Test';

  @override
  String get debugStop => 'Stop';

  @override
  String get debugInstallService => 'Install service';

  @override
  String get debugServiceUrl => 'Generic service index.js URL';

  @override
  String get debugServiceName => 'Service name (storage key, blank=from URL)';

  @override
  String get debugDefaultPort => 'Default port (blank=script default)';

  @override
  String get debugLoadLocalScript => 'Load local script';

  @override
  String get debugRegisteredServices => 'Registered services';

  @override
  String get debugNoService => 'No service';

  @override
  String get debugStartService => 'Start service';

  @override
  String get debugStopService => 'Stop service';

  @override
  String get debugUninstallService => 'Uninstall service';

  @override
  String get themeColor => 'Theme color';

  @override
  String get fontCardTitle => 'Fonts';

  @override
  String get fontDefault => 'Default';

  @override
  String get fontImport => 'Import font';

  @override
  String get fontImported => 'Font imported';

  @override
  String get fontImportFailed => 'Font import failed';

  @override
  String get fontExists => 'This font already exists';

  @override
  String get fontDelete => 'Delete font';

  @override
  String get fontDeleteConfirm => 'Delete this font?';

  @override
  String get featureLogging => 'Logging';

  @override
  String get logClear => 'Clear logs';

  @override
  String get logExport => 'Export logs';

  @override
  String get logClearConfirm => 'Clear all log records?';

  @override
  String get logClearAction => 'Clear';

  @override
  String get logCleared => 'Logs cleared';

  @override
  String get logClearFailed => 'Failed to clear logs';

  @override
  String get logNoFile => 'No log file';

  @override
  String get restoreInProgress => 'Restoring…';

  @override
  String get restoreDone =>
      'Data restored. The app will exit, please reopen it.';

  @override
  String get restoreWriteFailed =>
      'Restore failed. Restarting the app is recommended';

  @override
  String get restoreNotBackup => 'Not a valid NovaPlay backup file';

  @override
  String restoreFileFailed(String error) {
    return 'Failed to restore the file: $error';
  }

  @override
  String get backupRestoreSheetDescription =>
      'Choose items to restore. Local data of the same names will be overwritten by the backup.';

  @override
  String backupCreatedAt(String time) {
    return 'Backup time: $time';
  }

  @override
  String backupSourceVersion(String version, String platform) {
    return 'Source version: v$version ($platform)';
  }

  @override
  String get restoreConfirmTitle => 'Confirm restore';

  @override
  String get restoreConfirmBody =>
      'Selected data will be overwritten by the backup (extra local records will be lost). The app will then exit and needs to be reopened.';

  @override
  String get exportDoneTitle => 'Export complete';

  @override
  String exportSavedAs(String name) {
    return 'Backup file saved at: $name';
  }

  @override
  String get exportShareWarning =>
      'The backup may contain sensitive info such as accounts and passwords. Share with care.';

  @override
  String get share => 'Share';

  @override
  String get exporting => 'Exporting…';

  @override
  String get exportFailed => 'Export failed, please try again';

  @override
  String get shareFailed => 'Share failed';

  @override
  String get reload => 'Reload';

  @override
  String get catpawTimeoutError =>
      'Timed out connecting to the catpaw service, please try again later';

  @override
  String get catpawUnreachable =>
      'Cannot reach the catpaw service, please make sure the local service is running';

  @override
  String get catpawBadCertificate =>
      'The catpaw service certificate failed verification';

  @override
  String httpError(int code, String message) {
    return 'HTTP $code: $message';
  }

  @override
  String get playerLongPressSpeedAdjust =>
      'Slide to adjust the long-press speed';

  @override
  String get playerLongPressSpeedAdjustSub =>
      'Off: a long press always uses the fixed speed';

  @override
  String get playerMdkNote =>
      'MDK ships with the arm64-v8a build only; elsewhere the player falls back to Exo and says why.';

  @override
  String get playerIosAvplayerNote =>
      'AVPlayer uses Apple VideoToolbox hardware decoding with native iOS Picture-in-Picture, AirPlay video routing, and low power draw (best for HLS / MP4).';

  @override
  String get playerIosVlcNote =>
      'VLC uses FFmpeg / libvlc for MKV, FLV, AVI, embedded ASS subtitles, and HW/SW decode switching, without iOS system Picture-in-Picture.';

  @override
  String get playerHwDecodeIosAvSub =>
      'AVPlayer always uses VideoToolbox hardware decoding; this toggle applies to the VLC kernel';

  @override
  String get playerAutoPipIosVlcSub =>
      'iOS system Picture-in-Picture is available only with the AVPlayer kernel';

  @override
  String get playerSubtitleFontHintIos =>
      'iOS system font family (e.g. PingFang SC)';

  @override
  String get playerSubtitleNoteIos =>
      'Supports embedded subtitle tracks and external SRT, WebVTT, and ASS/SSA (importable from Files or URL inside the player).';

  @override
  String get playerReloadNote =>
      'Changing the kernel or hardware acceleration inside the player reloads the video at the current position.';

  @override
  String get searchSiteManager => 'Search sites';

  @override
  String get searchSwitchLayout => 'Switch layout';

  @override
  String get searchLayoutList => 'List';

  @override
  String get searchLayoutTop => 'Sites on top';

  @override
  String get searchLayoutLeft => 'Sites on the left';

  @override
  String get searchHistory => 'Search history';

  @override
  String get searchHistoryClear => 'Clear search history';

  @override
  String get searchHistoryClearConfirm => 'Clear all search history?';

  @override
  String get searchSearching => 'Searching…';

  @override
  String searchFailed(String error) {
    return 'Search failed: $error';
  }

  @override
  String get searchTwoColumns => 'Two columns';

  @override
  String get searchOneColumn => 'One column';

  @override
  String get searchNoSites => 'No sites yet. Add a subscription first';

  @override
  String searchSiteTab(String site, int count) {
    return '$site ($count)';
  }
}
