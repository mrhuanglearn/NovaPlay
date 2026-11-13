// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appName => '星映';

  @override
  String get tabHome => '首页';

  @override
  String get tabLive => '直播';

  @override
  String get tabCalendar => '追剧日历';

  @override
  String get tabLibrary => '媒体库';

  @override
  String get tabSettings => '设置';

  @override
  String get pressBackAgainToExit => '再按一次返回键退出应用';

  @override
  String get loadFailed => '加载失败';

  @override
  String get retry => '重试';

  @override
  String get paste => '粘贴';

  @override
  String get save => '保存';

  @override
  String get cancel => '取消';

  @override
  String get ok => '确定';

  @override
  String get add => '添加';

  @override
  String get delete => '删除';

  @override
  String get edit => '编辑';

  @override
  String get search => '搜索';

  @override
  String get all => '全部';

  @override
  String get goToSettings => '前往设置';

  @override
  String get noData => '暂无数据';

  @override
  String get nothingHere => '这里空空如也，什么都没有发现';

  @override
  String get settingsGroupData => '数据';

  @override
  String get settingsGroupPreferences => '偏好';

  @override
  String get settingsGroupTools => '工具';

  @override
  String get settingsSubscriptions => '订阅管理';

  @override
  String get settingsSubscriptionsSub => '管理数据源与自动更新';

  @override
  String get settingsLive => '直播';

  @override
  String get settingsLiveSub => '直播源管理与全局 EPG、屏蔽分类';

  @override
  String get settingsDanmu => '弹幕服务';

  @override
  String get settingsDanmuSub => '配置弹幕 API 地址与访问 Token';

  @override
  String get settingsMediaServer => '媒体服务器';

  @override
  String get settingsMediaServerSub => '管理 Emby、Jellyfin 服务器账号，浏览媒体库';

  @override
  String get settingsTmdb => 'TMDB 配置';

  @override
  String get settingsTmdbSub => '配置 API Key 与刮削代理';

  @override
  String get settingsWebdav => 'WebDAV 同步';

  @override
  String get settingsWebdavSub => '多端数据同步（可自选类型）';

  @override
  String get settingsBackup => '备份与恢复';

  @override
  String get settingsBackupSub => '打包数据为 zip 备份或分享，从备份恢复';

  @override
  String get settingsPlayer => '播放器';

  @override
  String get settingsPlayerSub => '播放内核、倍速、字幕与显示';

  @override
  String get settingsSniffer => '网页视频嗅探';

  @override
  String get settingsSnifferSub => '自动嗅探网页中的视频与流媒体资源';

  @override
  String get secondsShort => '秒';

  @override
  String get saved => '已保存';

  @override
  String get serverAddress => '服务器地址';

  @override
  String get port => '端口';

  @override
  String get tokenOptional => 'Token（可选）';

  @override
  String get testConnection => '测试连通';

  @override
  String get playerGroupPlayback => '播放';

  @override
  String get playerKernel => '播放内核';

  @override
  String get playerHwDecode => '硬件加速';

  @override
  String get playerFit => '画面填充';

  @override
  String get playerFitFit => '原比例';

  @override
  String get playerFitFill => '拉伸铺满';

  @override
  String get playerFitZoom => '裁剪铺满';

  @override
  String get playerDefaultSpeed => '默认倍速';

  @override
  String get playerLongPressSpeed => '长按倍速';

  @override
  String get playerDoubleTapSeek => '快进快退秒数';

  @override
  String get playerMpvNote => 'MPV 需要 APK 内带 libmpv.so；缺少时播放器页会回退到 Exo 并提示原因。';

  @override
  String get playerGroupSubtitles => '字幕与音频';

  @override
  String get playerSubtitleLang => '首选字幕语言';

  @override
  String get playerSubtitleFont => '字幕字体';

  @override
  String get playerSubtitleFontHint => '系统字体名，或字体目录中的文件名';

  @override
  String get playerFontsDir => '字体目录（可选）';

  @override
  String get playerAudioLang => '首选音轨语言';

  @override
  String get playerSubtitleNote =>
      '支持 SRT、WebVTT、TTML 和基础 ASS/SSA。ASS 由 Exo 的简易解析器绘制，不是 libass。';

  @override
  String get playerGroupBehaviour => '行为';

  @override
  String get playerPreferLandscape => '优先横屏';

  @override
  String get playerAutoPip => '进入后台自动画中画';

  @override
  String get playerPauseInBackground => '进入后台暂停';

  @override
  String get playerSkipNotice => '跳过提示';

  @override
  String get playerEpisodeSwitchNotice => '切集提示';

  @override
  String get playerHaptics => '触感反馈';

  @override
  String get playerGroupOverlay => '信息显示';

  @override
  String get playerShowNetSpeed => '始终显示网速';

  @override
  String get playerShowStats => '显示帧率与编码';

  @override
  String get playerShowTotalDuration => '进度条显示总时长';

  @override
  String get playerHideSeekButtons => '隐藏中央快进快退';

  @override
  String get danmuEnable => '启用弹幕';

  @override
  String get danmuSource => '弹幕服务来源';

  @override
  String get danmuModeOff => '关闭';

  @override
  String get danmuModeBuiltin => '本地服务';

  @override
  String get danmuModeSubscription => '订阅自带';

  @override
  String get danmuModeRemote => '自定义远程';

  @override
  String get danmuModeOffNote => '不使用弹幕服务。';

  @override
  String get danmuModeBuiltinNote => '在内置 Node 运行时里运行你提供的 danmu_api 脚本。';

  @override
  String get danmuModeSubscriptionNote => '使用当前订阅的 9321 端口。';

  @override
  String get danmuModeRemoteNote => '你自己的 danmu_api 服务器。';

  @override
  String get danmuScriptUrl => 'danmu_api 脚本地址（server.cjs）';

  @override
  String get danmuDownloadScript => '下载 / 更新脚本';

  @override
  String danmuScriptDownloaded(String md5) {
    return '脚本已下载（md5 $md5）';
  }

  @override
  String get danmuNotReachable => '无法连接或未配置';

  @override
  String danmuReachable(int count) {
    return '已连通（搜索 “a” 得到 $count 条结果）';
  }

  @override
  String get danmuGroupAppearance => '外观';

  @override
  String get danmuOpacity => '透明度';

  @override
  String get danmuFontSize => '字号';

  @override
  String get danmuScrollSpeed => '滚动速度';

  @override
  String get danmuArea => '显示区域';

  @override
  String get danmuDelay => '弹幕延迟';

  @override
  String get danmuTop => '顶部弹幕';

  @override
  String get danmuBottom => '底部弹幕';

  @override
  String get danmuBlockedWords => '屏蔽词';

  @override
  String get danmuBlockedWordsHint => '每行一个';

  @override
  String get connectionOk => '连接成功';

  @override
  String get advanced => '高级';

  @override
  String get language => '语言';

  @override
  String get password => '密码';

  @override
  String get restore => '恢复';

  @override
  String get copied => '已复制';

  @override
  String get clipboardEmpty => '剪贴板为空';

  @override
  String get tmdbConnectionFailed => '连接失败（请检查 Key 与地址）';

  @override
  String get tmdbConnectTitle => '连接 TMDB';

  @override
  String get tmdbConnectDescription => '连接后自动匹配海报、简介与演员信息，追剧日历同步更新';

  @override
  String get tmdbEnable => '启用 TMDB';

  @override
  String get tmdbEnableSub => '海报、剧集名与追剧日历';

  @override
  String get tmdbKeyHint => '请填写 TMDB API Key (v3) 或读取访问令牌 (v4)，自动识别';

  @override
  String get tmdbApiBase => 'API 地址（留空为官方）';

  @override
  String get tmdbImageBase => '图片地址（留空为官方）';

  @override
  String get tmdbMatchWait => '详情页匹配等待（秒）';

  @override
  String get tmdbKeyStorageNote =>
      'Key 以明文保存在 tmdb_settings.json 中，并会包含在 WebDAV 同步与备份里。';

  @override
  String get webdavAccount => '账户名称';

  @override
  String get webdavSubFolder => '子目录（可选）';

  @override
  String get webdavSubFolderHint => '共用同一个 WebDAV 时用于隔离数据，留空使用根目录';

  @override
  String get webdavSyncNow => '立即同步';

  @override
  String webdavSyncResult(int pushed, int pulled) {
    return '已上传 $pushed 个、下载 $pulled 个文档';
  }

  @override
  String get webdavNote =>
      '同步收藏、历史、播放进度、TMDB 匹配与 Key、追剧、播放器与直播设置。密码与 TMDB Key 以明文保存。';

  @override
  String get webdavNotConfigured => '请先配置 WebDAV';

  @override
  String get backupGroupExport => '导出备份';

  @override
  String get backupGroupRestore => '从备份恢复';

  @override
  String get backupShareFile => '分享备份文件';

  @override
  String get backupShareFileSub => '一个包含所有同步文档的 JSON 文件';

  @override
  String get backupShareText => '星映 备份';

  @override
  String get backupCopy => '复制备份到剪贴板';

  @override
  String get backupRestoreClipboard => '从剪贴板恢复';

  @override
  String get backupRestoreWebdav => '从 WebDAV 恢复';

  @override
  String get backupRestoreWebdavSub => '以远端的每个文档为准';

  @override
  String backupRestored(int count) {
    return '已恢复 $count 个文档';
  }

  @override
  String get backupSensitiveNote => '备份可能包含账号、密码等敏感信息，分享时请注意。';

  @override
  String get name => '名称';

  @override
  String get subscriptions => '订阅';

  @override
  String get subscriptionAdd => '添加订阅';

  @override
  String get subscriptionsEmptyTitle => '还没有订阅';

  @override
  String get subscriptionsEmptySubtitle => '添加一个订阅源，开始聚合你的内容';

  @override
  String get subscriptionDelete => '删除订阅';

  @override
  String subscriptionDeleteConfirm(String name) {
    return '确定删除「$name」？';
  }

  @override
  String get subscriptionKindNetwork => '网络';

  @override
  String get subscriptionKindCloud => '云端';

  @override
  String get subscriptionNetworkHint => '添加一个数据源以聚合内容';

  @override
  String get subscriptionCloudHint => '直连运行在云端的 catpaw 服务，无需下载脚本';

  @override
  String get subscriptionSourceUrl => '数据源地址';

  @override
  String get subscriptionCloudAddress => '云端服务地址';

  @override
  String get subscriptionNameHint => '留空将自动从地址生成';

  @override
  String get subscriptionDanmuToken => '弹幕服务 Token（可选）';

  @override
  String get subscriptionDanmuTokenHint => '订阅自带弹幕服务的路径前缀';

  @override
  String get subscriptionLock => '上锁';

  @override
  String get subscriptionLockSub => '上锁后需验证锁密码才可见';

  @override
  String get subscriptionUrlRequired => '请填写数据源地址';

  @override
  String get filter => '筛选';

  @override
  String get homeCatpawUnavailable => '无法连接到 catpaw 服务';

  @override
  String get libraryHistory => '播放历史';

  @override
  String get libraryFavorites => '我的收藏';

  @override
  String get libraryDownloads => '下载';

  @override
  String get historyEmptySubtitle => '暂无播放记录，去看看想看的内容吧';

  @override
  String get favoritesEmptyTitle => '还没有收藏内容';

  @override
  String get favoritesEmptySubtitle => '暂无收藏，去发现喜欢的视频吧';

  @override
  String get downloadsEmptyTitle => '暂无下载任务';

  @override
  String get downloadsEmptySubtitle => '暂无下载任务';

  @override
  String get downloadsOtherGroup => '其他';

  @override
  String downloadsDoneCount(int done, int total) {
    return '已完成 $done/$total';
  }

  @override
  String get downloadQueued => '等待中';

  @override
  String get downloadRunning => '下载中';

  @override
  String get downloadPaused => '已暂停';

  @override
  String get downloadDone => '已完成';

  @override
  String get downloadFailed => '失败';

  @override
  String get downloadPause => '暂停';

  @override
  String get downloadResume => '继续';

  @override
  String get noResults => '没有找到结果';

  @override
  String get mediaSeries => '剧集';

  @override
  String get mediaMovie => '电影';

  @override
  String get tmdbNotEnabledError => '请先在设置中启用 TMDB 并填写 API Key';

  @override
  String get tmdbSearchHint => '搜索 TMDB';

  @override
  String get tmdbSearchPrompt => '输入片名后搜索';

  @override
  String get trackingSeason => '季';

  @override
  String get trackingSeasonNumber => '第几季';

  @override
  String get trackingManage => '追剧管理';

  @override
  String get trackingAdd => '添加追剧';

  @override
  String get trackingAutoSync => '自动同步收藏到追剧日历';

  @override
  String get trackingAutoSyncSub => '收藏匹配到的电视剧会自动添加到追剧日历';

  @override
  String get trackingEmpty => '还没有追剧';

  @override
  String get trackingFollowed => '正在追';

  @override
  String trackingShowSubtitle(int season, int watched) {
    return '第 $season 季 · 已看 $watched 集';
  }

  @override
  String get calendarTmdbDisabled => '未启用 TMDB，无法获取更新日历';

  @override
  String get calendarThisWeek => '本周';

  @override
  String get calendarNothingThisWeek => '本周没有更新';

  @override
  String calendarEpisode(int number, String name) {
    return '第 $number 集 $name';
  }

  @override
  String get markedWatched => '已标记为已看';

  @override
  String get markedUnwatched => '已标记为未看';

  @override
  String get liveSearchChannels => '搜索频道';

  @override
  String get liveSettings => '直播设置';

  @override
  String get liveEmptyTitle => '还没有直播源';

  @override
  String get liveEmptySubtitle => '添加一个 M3U 直播源开始观看';

  @override
  String get liveAddSource => '添加直播源';

  @override
  String get liveEditSource => '编辑直播源';

  @override
  String get liveNoChannels => '没有频道';

  @override
  String get liveSourcesGroup => '直播源管理';

  @override
  String get liveBlockedGroup => '屏蔽分类管理';

  @override
  String get liveBlockedCategories => '屏蔽分类';

  @override
  String get liveBlockedCategoriesSub => '屏蔽后隐藏对应分类的频道';

  @override
  String get liveM3uUrl => 'M3U 地址';

  @override
  String get liveEpgUrl => 'EPG 地址（可选）';

  @override
  String get favorite => '收藏';

  @override
  String get notFound => '未找到';

  @override
  String get downloadStarted => '已开始下载';

  @override
  String get addedToCalendar => '已添加到追剧日历';

  @override
  String detailDirector(String name) {
    return '导演: $name';
  }

  @override
  String detailCast(String names) {
    return '演职员: $names';
  }

  @override
  String get detailMatchTmdb => '匹配 TMDB';

  @override
  String get detailNoLines => '暂无可播放线路';

  @override
  String get detailLongPressToDownload => '长按剧集即可下载。';

  @override
  String get searchHint => '搜索影视…';

  @override
  String get searchPrompt => '输入关键词，跨所有站源聚合搜索';

  @override
  String get userName => '用户名';

  @override
  String get signIn => '登录';

  @override
  String signInFailed(String error) {
    return '登录失败：$error';
  }

  @override
  String get play => '播放';

  @override
  String get embyAddServer => '添加服务器';

  @override
  String get embyServerType => '类型';

  @override
  String get embyEmptyTitle => '还没有服务器';

  @override
  String get embySearchLibrary => '搜索媒体库';

  @override
  String get embyAccountNotFound => '找不到该账号';

  @override
  String get embyContinueWatching => '继续观看';

  @override
  String get embyLatest => '最新';

  @override
  String embySeason(int season) {
    return '第 $season 季';
  }

  @override
  String get embyInProgress => '观看中';

  @override
  String get snifferNothingYet => '还没有嗅探到资源，请在页面上开始播放视频。';

  @override
  String get snifferPrompt => '输入网页地址以查找视频';

  @override
  String get webAddressHint => '网址';

  @override
  String get configChecksumMismatchTitle => '配置文件校验不一致';

  @override
  String get configChecksumMismatchBody =>
      'index.config.js 的 md5 与校验文件不一致（订阅作者可能未更新 .md5）。仍要使用该配置吗？';

  @override
  String get done => '完成';

  @override
  String get selectAll => '全选';

  @override
  String get deselectAll => '取消全选';

  @override
  String selectedCount(int count) {
    return '已选 $count 项';
  }

  @override
  String get subscriptionKindLocal => '本地';

  @override
  String get subscriptionLocalHint =>
      '选择本地 zip 压缩包作为订阅源，需同时包含 index.js 与 index.config.js';

  @override
  String get subscriptionLocalArchive => '本地压缩包';

  @override
  String get subscriptionPickArchive => '选择压缩包';

  @override
  String get subscriptionChipNetwork => '网络地址';

  @override
  String get subscriptionChipCloud => '云端服务';

  @override
  String get subscriptionChipLocal => '本地压缩包';

  @override
  String get subscriptionAutoUpdate => '自动更新';

  @override
  String get subscriptionAutoUpdateSub => '随启动自动同步最新内容';

  @override
  String get subscriptionLockSingle => '仅有一个订阅时不支持上锁';

  @override
  String get subscriptionInstallUntrusted => '安装不受信任的订阅';

  @override
  String get subscriptionConnectCloud => '连接云端服务';

  @override
  String get subscriptionCantAdd => '无法添加？';

  @override
  String get notice => '提示';

  @override
  String get subscriptionCantAddHelp =>
      '因个人网络环境不同，若遇到无法连接或下载失败，请尝试 【开启代理并开启代理工具的 TUN 模式】 或 【关闭代理】后再试。';

  @override
  String get added => '已添加';

  @override
  String get subscriptionDuplicate => '该 URL 的订阅已存在';

  @override
  String subscriptionDownloadFailed(String error) {
    return '下载订阅文件失败：$error';
  }

  @override
  String subscriptionZipFailed(String error) {
    return '安装本地压缩包失败：$error';
  }

  @override
  String get subscriptionZipRequired => '请先选择压缩包';

  @override
  String get subscriptionLastUpdated => '上次更新';

  @override
  String subscriptionLastUpdatedAt(String when) {
    return '上次更新 $when';
  }

  @override
  String get timeJustNow => '刚刚';

  @override
  String timeMinutesAgo(int n) {
    return '$n 分钟前';
  }

  @override
  String timeHoursAgo(int n) {
    return '$n 小时前';
  }

  @override
  String timeDaysAgo(int n) {
    return '$n 天前';
  }

  @override
  String get subscriptionActivate => '激活';

  @override
  String get subscriptionActive => '已激活';

  @override
  String subscriptionSwitchedTo(String name) {
    return '已切换到 $name';
  }

  @override
  String get subscriptionCannotDeleteActive => '无法删除已激活的订阅，请先切换到其他数据源';

  @override
  String subscriptionDeleteSelectedConfirm(int count) {
    return '确定删除选中的 $count 项订阅吗？此操作不可撤销。';
  }

  @override
  String subscriptionDeleteOneConfirm(String name) {
    return '确定删除「$name」吗？此操作不可撤销。';
  }

  @override
  String subscriptionUpToDate(String name) {
    return '「$name」已是最新';
  }

  @override
  String get subscriptionUpdatedOne => '已更新到最新';

  @override
  String subscriptionUpdatedCount(int count) {
    return '已更新 $count 个订阅';
  }

  @override
  String get subscriptionAllUpToDate => '所有订阅均为最新';

  @override
  String subscriptionCheckFailed(String error) {
    return '检查订阅更新失败（$error）';
  }

  @override
  String get subscriptionChecking => '正在检查订阅更新…';

  @override
  String get subscriptionEdit => '编辑订阅';

  @override
  String get subscriptionFingerprint => '内容指纹';

  @override
  String get subscriptionReplaceZip => '替换本地脚本';

  @override
  String get subscriptionReplaceZipSub => '重新选择 zip 压缩包以覆盖当前本地源';

  @override
  String get subscriptionNotFound => '订阅不存在';

  @override
  String get homeSwitchSite => '切换站点';

  @override
  String get homeSiteSettings => '站点设置';

  @override
  String get homeSiteEnable => '启用';

  @override
  String get homeSiteHistory => '历史记录';

  @override
  String get homeSiteWebsite => '网页';

  @override
  String get homeSiteUnlock => '解锁站点';

  @override
  String get homeBlockCategories => '分类屏蔽';

  @override
  String get homeHideFilters => '隐藏筛选';

  @override
  String get homeShowFilters => '显示筛选';

  @override
  String get homeSwitchLayout => '切换布局';

  @override
  String get homeNoBlockableCategories => '当前站点已无可屏蔽的分类';

  @override
  String get homePushNotSupported => '当前订阅不支持推送解析';

  @override
  String get homePushTitle => '推送解析';

  @override
  String get homePushHint => '粘贴分享链接…';

  @override
  String get homePushDescription => '粘贴网盘分享链接或视频直链，自动解析播放线路';

  @override
  String get homeNoSites => '暂无可用站点，请先添加订阅';

  @override
  String get detailPlayNow => '立即播放';

  @override
  String get detailEpisodes => '选集';

  @override
  String get detailIntro => '简介';

  @override
  String detailEpisodeSheetSub(String line, int count) {
    return '$line · $count集';
  }

  @override
  String get detailLocateCurrent => '定位到当前集';

  @override
  String get detailReverseOrder => '倒序';

  @override
  String get searchEmptyTitle => '搜索影视';

  @override
  String get mediaAccountsTitle => '媒体服务器账号';

  @override
  String get mediaEmptySubtitle => '添加一个账号以浏览你的 Emby 媒体库';

  @override
  String get mediaAddAccount => '添加账号';

  @override
  String get mediaServerType => '服务器类型';

  @override
  String get mediaAutoDetect => '自动探测';

  @override
  String get mediaAddressHint => '如 http://192.168.1.10:8096';

  @override
  String get mediaPasswordHint => '可留空';

  @override
  String get mediaSignInAndSave => '登录并保存';

  @override
  String get mediaAccountExists => '该账号已存在';

  @override
  String get mediaSignedIn => '登录成功';

  @override
  String get mediaAddressRequired => '请填写服务器地址';

  @override
  String mediaDeleteConfirm(String name) {
    return '确定删除「$name」吗？删除后需重新登录才能访问该服务器。';
  }

  @override
  String get tmdbConnect => '连接';

  @override
  String get tmdbGetKey => '去申请 API Key';

  @override
  String get tmdbConnected => '已连接 TMDB';

  @override
  String get tmdbDisconnect => '断开连接';

  @override
  String get tmdbDisconnectTitle => '断开 TMDB 连接？';

  @override
  String get tmdbDisconnectBody => '将清除 API Key 并停用 TMDB 功能，代理配置会保留';

  @override
  String get tmdbProxyGroup => '代理与高级';

  @override
  String get webdavEmptyTitle => '尚未配置 WebDAV 同步';

  @override
  String get webdavEmptySubtitle => '添加服务地址、账号和密码，即可在多设备间同步你的数据';

  @override
  String get webdavAddConfig => '添加配置';

  @override
  String get webdavConfigTitle => 'WebDAV 配置';

  @override
  String get webdavEditConfig => '编辑配置';

  @override
  String get webdavIsolation => '隔离名称';

  @override
  String get webdavIsolationHint => '多人共用同一 WebDAV 时用于数据隔离，留空则使用根目录';

  @override
  String get webdavServiceAddress => '服务地址';

  @override
  String get webdavServiceAddressHint => '如 https://dav.jianguoyun.com/dav/';

  @override
  String get webdavAccountLabel => '账号';

  @override
  String get webdavAccountHint => 'WebDAV 账号名';

  @override
  String get webdavPasswordHint => '应用专属密码';

  @override
  String get webdavFillRequired => '请先填写服务地址、账号和密码';

  @override
  String get webdavConnectFailed => 'WebDAV 连接失败';

  @override
  String get webdavAuthFailed => 'WebDAV 认证失败，请检查账号密码';

  @override
  String get webdavEnableSync => '启用同步';

  @override
  String get webdavEnableSyncSub => '启动应用时自动同步所选数据';

  @override
  String get webdavSyncing => '正在同步…';

  @override
  String get webdavNeverSynced => '尚未同步';

  @override
  String webdavLastSync(String time) {
    return '上次同步 $time';
  }

  @override
  String get webdavSyncDone => '同步完成';

  @override
  String webdavSyncFailed(String error) {
    return 'WebDAV 同步失败：$error';
  }

  @override
  String get webdavNoTypes => '未选择任何数据类型';

  @override
  String get webdavTypesGroup => '同步内容';

  @override
  String get webdavTypeFavorites => '收藏';

  @override
  String get webdavTypeFavoritesSub => '收藏与“自动同步收藏到追剧日历”';

  @override
  String get webdavTypeHistory => '观看历史与进度';

  @override
  String get webdavTypeHistorySub => '播放历史、播放进度与上次观看的集';

  @override
  String get webdavTypeTracking => '追剧';

  @override
  String get webdavTypeTrackingSub => '追剧日历中的剧集';

  @override
  String get webdavTypeTmdb => 'TMDB 配置与匹配';

  @override
  String get webdavTypeTmdbSub =>
      '同步 TMDB 开关、API Key 与代理地址（组级整体覆盖）及匹配记录；API Key 将以明文存储于 WebDAV 服务端';

  @override
  String get webdavTypePlayer => '播放器设置';

  @override
  String get webdavTypePlayerSub => '播放器设置与片头片尾记录';

  @override
  String get webdavTypeLive => '直播';

  @override
  String get webdavTypeLiveSub => '直播源、全局 EPG 与屏蔽分类';

  @override
  String get liveGlobalEpg => '全局 EPG 地址';

  @override
  String get liveGlobalEpgHint =>
      '直播源未自带 EPG 时使用，如 https://example.com/epg.xml.gz';

  @override
  String get liveEpgSaved => 'EPG 地址已保存';

  @override
  String get liveSourceUrl => '源地址';

  @override
  String get liveNameHint => '如：我的直播源';

  @override
  String get liveM3uOnly => '仅支持 M3U 格式播放列表';

  @override
  String get liveAutoRefresh => '自动刷新';

  @override
  String get liveRefreshOff => '关闭';

  @override
  String get liveRefreshAlways => '每次';

  @override
  String get liveRefresh24h => '24 小时';

  @override
  String get liveVerifyAndSave => '验证并保存';

  @override
  String get liveSourceSaved => '直播源已保存';

  @override
  String liveSourceSaveFailed(String error) {
    return '直播源保存失败: $error';
  }

  @override
  String get liveSourceExists => '该地址的直播源已存在';

  @override
  String liveDeleteConfirm(String name) {
    return '确定删除直播源「$name」吗？';
  }

  @override
  String get liveSourceDeleted => '直播源已删除';

  @override
  String get liveBlockedEmpty => '暂无屏蔽分类';

  @override
  String get liveBlockPick => '选择要屏蔽的分类';

  @override
  String get liveNothingToBlock => '没有可屏蔽的分类';

  @override
  String liveCategoryBlocked(String name) {
    return '已屏蔽分类「$name」';
  }

  @override
  String liveCategoryUnblocked(String name) {
    return '已取消屏蔽「$name」';
  }

  @override
  String get liveUserAgentHint => '输入自定义 User-Agent';

  @override
  String get danmuStatus => '运行状态';

  @override
  String get danmuStopped => '已停止';

  @override
  String danmuRunning(String port) {
    return '运行中 : $port';
  }

  @override
  String get danmuNoService => '尚未添加弹幕服务';

  @override
  String get danmuNoServiceSub => '在下方添加网络订阅或本地脚本';

  @override
  String get danmuOpenWeb => '打开网页';

  @override
  String get danmuRestart => '重启服务';

  @override
  String get danmuStop => '关闭服务';

  @override
  String get danmuNotReady => '服务未就绪，无法打开网页';

  @override
  String get danmuNetworkSource => '网络订阅源';

  @override
  String get danmuLocalScriptTab => '本地脚本';

  @override
  String get danmuSourceUrl => '订阅源 URL（.cjs.md5）';

  @override
  String get danmuDownload => '下载脚本';

  @override
  String get danmuLoadLocal => '加载本地脚本';

  @override
  String get danmuReplaceLocal => '替换本地脚本';

  @override
  String get danmuLocalLoaded => '本地脚本加载成功';

  @override
  String danmuLocalOnlyCjs(String name) {
    return '仅支持 .cjs/.js 文件（当前: $name）';
  }

  @override
  String get danmuRemoteHint => 'http://ip:9321 或 http://ip:9321/TOKEN';

  @override
  String get danmuShowTop => '显示顶部弹幕';

  @override
  String get danmuShowBottom => '显示底部弹幕';

  @override
  String get danmuShowPositionSub => '关闭后该位置弹幕改为滚动显示';

  @override
  String get danmuColor => '弹幕颜色';

  @override
  String get danmuColorOriginal => '自带色';

  @override
  String get danmuColorWhite => '白色';

  @override
  String get danmuColorRandom => '随机(纯色)';

  @override
  String get danmuLineHeight => '行间距';

  @override
  String get danmuStroke => '描边';

  @override
  String get danmuBlockedWordsTitle => '屏蔽词管理';

  @override
  String get danmuBlockedWordsEmpty => '暂无屏蔽词，命中屏蔽词的弹幕将被过滤';

  @override
  String get danmuBlockedWordAdd => '添加屏蔽词';

  @override
  String get playerGroupDecode => '解码';

  @override
  String get playerGroupPicture => '画面与内核';

  @override
  String get playerHwDecodeSub => '关闭后使用软解（更兼容但更耗电）';

  @override
  String get playerShowTotalDurationSub => '关闭则显示剩余时长';

  @override
  String get playerAutoPipSub => '切到后台时自动开启画中画继续播放';

  @override
  String get playerSkipNoticeSub => '跳过片头片尾时显示横幅与轻提示';

  @override
  String get playerEpisodeSwitchNoticeSub => '切集时显示「正在切换至 第x集」轻提示';

  @override
  String get playerShowStatsSub => '影响观影性能';

  @override
  String get playerShowNetSpeedSub => '无需开启上方信息栏即可看到下载速度';

  @override
  String get backupExportItems => '选择数据项并导出';

  @override
  String get backupExportItemsSub => '打包为 zip 保存到 Backups';

  @override
  String get backupRestoreFile => '选择备份文件恢复';

  @override
  String get backupRestoreFileSub => '从 zip 备份包覆盖恢复数据（也支持旧的 JSON 备份）';

  @override
  String get backupSheetDescription =>
      '勾选要导出的数据项。订阅配置、应用设置与账号等可能含有账号、密码、令牌，将以明文写入备份文件。';

  @override
  String get backupSensitiveWarning =>
      '所选数据包含账号、密码、令牌等敏感信息，将以明文写入备份文件，请妥善保管、谨慎分享。';

  @override
  String get backupExportButton => '导出';

  @override
  String get backupGroupUser => '用户数据';

  @override
  String get backupGroupSubscriptions => '订阅与弹幕服务';

  @override
  String get backupGroupPreferences => '偏好设置';

  @override
  String get backupItemHistory => '播放历史';

  @override
  String get backupItemFavorites => '收藏';

  @override
  String get backupItemProgress => '播放进度';

  @override
  String get backupItemLastEpisode => '上次集数';

  @override
  String get backupItemTmdbRefs => 'TMDB 匹配';

  @override
  String get backupItemHeadTail => '片头片尾';

  @override
  String get backupItemTracking => '追剧';

  @override
  String get backupItemDanmuRefs => '弹幕匹配';

  @override
  String get backupItemLive => '直播源';

  @override
  String get backupItemSubscriptions => '订阅列表';

  @override
  String get backupItemAppSettings => '应用设置（含弹幕服务配置）';

  @override
  String get backupItemAccounts => '媒体服务器与 WebDAV 账号';

  @override
  String get backupRestoreWebdavTitle => '从 WebDAV 恢复';

  @override
  String get webSearchHint => '输入网址或搜索关键词';

  @override
  String get webGo => '前往';

  @override
  String get webClearList => '清空列表';

  @override
  String get webOpenExternal => '在外部浏览器打开';

  @override
  String get webClearCookies => '清空网页 Cookie';

  @override
  String get webCookiesCleared => 'WebView Cookie 已清空';

  @override
  String get webUaDefault => '默认';

  @override
  String get webUaDesktop => '桌面 Chrome';

  @override
  String get webUaCustom => '自定义...';

  @override
  String get webReload => '刷新';

  @override
  String get webSniffed => '嗅探结果';

  @override
  String get languageSystem => '跟随系统';

  @override
  String get languageZh => '简体中文';

  @override
  String get languageEn => 'English';

  @override
  String get settingsTheme => '主题设置';

  @override
  String get settingsThemeSub => '配色、暗黑风格、字体大小';

  @override
  String get themeCustomize => '外观与主题定制';

  @override
  String get themeModeLabel => '主题模式';

  @override
  String get themeAuto => '自适应';

  @override
  String get themeLight => '亮色';

  @override
  String get themeDark => '暗色';

  @override
  String get themeDarkStyle => '暗色背景风格';

  @override
  String get themeDarkGray => '深灰底';

  @override
  String get themeDarkBlack => '纯黑底';

  @override
  String get themeFontSize => '字体大小';

  @override
  String get settingsFeatures => '功能设置';

  @override
  String get settingsFeaturesSub => '行为偏好与开关';

  @override
  String get catpawTimeout => 'catpaw 服务超时';

  @override
  String get catpawTimeoutSub => 'catpaw 数据请求的接收等待上限';

  @override
  String get catpawTimeoutField => '接收超时（秒）';

  @override
  String get settingsCleanup => '数据清理';

  @override
  String get settingsCleanupSub => '选择要清理的项目';

  @override
  String get cleanupDescription => '勾选要清理的项目，点击底部按钮执行。';

  @override
  String get cleanupGroupCache => '缓存';

  @override
  String get cleanupImages => '图片缓存';

  @override
  String get cleanupTemp => '临时文件';

  @override
  String get cleanupLivePlaylists => '直播列表缓存';

  @override
  String get cleanupRun => '清理选中项';

  @override
  String cleanupDone(int count) {
    return '已清理 $count 项';
  }

  @override
  String cleanupFailed(String error) {
    return '清理失败：$error';
  }

  @override
  String get settingsHomeTabs => '主页页面';

  @override
  String get settingsHomeTabsSub => '配置主页展示的页面及其顺序';

  @override
  String get homeTabsEnabled => '已启用';

  @override
  String get homeTabsDisabled => '未启用';

  @override
  String get homeTabsHint => '长按拖拽调整顺序';

  @override
  String get homeTabsRequired => '必需页面，不可关闭';

  @override
  String get downloadsManage => '下载管理';

  @override
  String get mediaManageAccounts => '管理账号';

  @override
  String get lockPassword => '锁密码';

  @override
  String get lockNotSet => '未设置';

  @override
  String get lockSet => '已设置';

  @override
  String get lockEmpty => '空密码';

  @override
  String get lockStateNotSet => '尚未设置锁密码';

  @override
  String get lockStateSet => '当前已设置锁密码';

  @override
  String get lockStateEmpty => '当前为空密码（无密码保护）';

  @override
  String get lockStepNew => '输入新密码';

  @override
  String get lockStepConfirm => '再次输入确认';

  @override
  String get lockStepOld => '验证旧密码';

  @override
  String get lockTapHint => '点击色块输入密码';

  @override
  String get lockTooShort => '请至少输入一位';

  @override
  String get lockMismatch => '两次输入不一致，请重试';

  @override
  String get lockWrongOld => '旧密码错误';

  @override
  String get lockUpdated => '锁密码已更新';

  @override
  String get lockCleared => '已清除锁密码';

  @override
  String get lockSetEmpty => '已设为空密码';

  @override
  String get lockVerifyTitle => '验证锁密码';

  @override
  String get lockFirstTitle => '首次上锁';

  @override
  String get lockFirstBody => '是否设置锁密码？不设置则使用空密码（无密码保护）。';

  @override
  String get lockSkip => '不设置';

  @override
  String get lockClear => '清除';

  @override
  String get lockNext => '下一步';

  @override
  String get lockConfirm => '确认';

  @override
  String get lockUnlock => '解锁';

  @override
  String get lockHiddenSubscriptions => '有已上锁的订阅被隐藏';

  @override
  String get lockUnlockSubscriptions => '解锁订阅';

  @override
  String get lockRelock => '重新上锁';

  @override
  String get lockHomeTitle => '订阅已上锁';

  @override
  String get lockHomeSubtitle => '当前订阅已上锁，请解锁后查看';

  @override
  String get lockBackspace => '删除';

  @override
  String get settingsReset => '重置应用';

  @override
  String get settingsResetSub => '清空全部数据并重启';

  @override
  String get resetConfirmBody =>
      '将清空所有本地数据（订阅、历史、收藏、设置、字体、下载、catpaw 实例数据等全部内容）并重启应用，相当于恢复出厂。已导出的备份文件会保留。此操作不可撤销，确定继续？';

  @override
  String get resetInProgress => '正在重置…';

  @override
  String get resetDone => '所有数据已清空，应用将退出，请重新打开。';

  @override
  String get resetFailed => '重置失败，请重试';

  @override
  String get settingsGroupDeveloper => '开发者';

  @override
  String get settingsCatpawDebug => 'catpaw 调试';

  @override
  String get settingsCatpawDebugSub => '启动与管理 catpaw 实例、查看运行日志';

  @override
  String get debugTitle => 'catpaw 多实例';

  @override
  String get debugStartTitle => '启动 catpaw 运行时';

  @override
  String get debugStartSub => '启动内嵌 Node 运行时，加载与管理 catpaw 实例及通用服务';

  @override
  String get debugDartPort => 'Dart 回调端口（空=随机）';

  @override
  String get debugStartNode => 'Start Node';

  @override
  String get debugNodeStarting => 'Node.js 正在启动…';

  @override
  String get debugNodeRunning => 'Node 运行中';

  @override
  String get debugLastResult => '最近结果';

  @override
  String get debugCopyLast => '复制 Last';

  @override
  String get debugCopiedLast => '已复制 Last';

  @override
  String get debugLog => '日志';

  @override
  String get debugNoLogs => '暂无日志';

  @override
  String get debugCopyAllLogs => '复制全部日志';

  @override
  String get debugClearLogs => '清空日志';

  @override
  String get debugLogsCleared => '日志已清空';

  @override
  String get debugTabServices => '通用服务';

  @override
  String get debugLoadInstance => '加载实例';

  @override
  String get debugInstanceName => '实例名（存储隔离键，空则取 URL 账号）';

  @override
  String get debugPort => '端口（空=随机）';

  @override
  String get debugForceRestart => '已存在则强制重启';

  @override
  String get debugNetAudit => '网络审计(记录该实例出站请求)';

  @override
  String get debugServiceLog => '服务日志(转发该实例 console)';

  @override
  String get debugLoadButton => '加载 catpaw 实例';

  @override
  String get debugRunningInstances => '运行实例';

  @override
  String get debugNoInstance => '无实例';

  @override
  String get debugTest => '测试';

  @override
  String get debugStop => '停止';

  @override
  String get debugInstallService => '安装服务';

  @override
  String get debugServiceUrl => '通用服务 index.js URL';

  @override
  String get debugServiceName => '服务名（存储隔离键，空则取 URL 账号）';

  @override
  String get debugDefaultPort => '默认端口（空=脚本自决）';

  @override
  String get debugLoadLocalScript => '加载本地脚本';

  @override
  String get debugRegisteredServices => '已注册服务';

  @override
  String get debugNoService => '无服务';

  @override
  String get debugStartService => '启动服务';

  @override
  String get debugStopService => '停止服务';

  @override
  String get debugUninstallService => '卸载服务';

  @override
  String get themeColor => '主题色彩';

  @override
  String get fontCardTitle => '字体';

  @override
  String get fontDefault => '默认';

  @override
  String get fontImport => '导入字体';

  @override
  String get fontImported => '字体导入成功';

  @override
  String get fontImportFailed => '字体导入失败';

  @override
  String get fontExists => '该字体已存在';

  @override
  String get fontDelete => '删除字体';

  @override
  String get fontDeleteConfirm => '确定删除该字体吗？';

  @override
  String get featureLogging => '日志记录';

  @override
  String get logClear => '清空日志';

  @override
  String get logExport => '导出日志';

  @override
  String get logClearConfirm => '确定清空所有日志记录吗？';

  @override
  String get logClearAction => '清空';

  @override
  String get logCleared => '日志已清空';

  @override
  String get logClearFailed => '清理日志失败';

  @override
  String get logNoFile => '暂无日志文件';

  @override
  String get restoreInProgress => '正在恢复…';

  @override
  String get restoreDone => '数据已恢复，应用即将退出，请重新打开。';

  @override
  String get restoreWriteFailed => '恢复过程中出错，建议重启应用';

  @override
  String get restoreNotBackup => '不是有效的星映备份包';

  @override
  String restoreFileFailed(String error) {
    return '恢复文件失败: $error';
  }

  @override
  String get backupRestoreSheetDescription => '勾选要恢复的数据项，将以备份包内容覆盖本地同名数据。';

  @override
  String backupCreatedAt(String time) {
    return '备份时间：$time';
  }

  @override
  String backupSourceVersion(String version, String platform) {
    return '来源版本：v$version（$platform）';
  }

  @override
  String get restoreConfirmTitle => '确认恢复';

  @override
  String get restoreConfirmBody =>
      '选中的数据将被备份包内容覆盖（本地多出的记录会丢失），完成后应用将自动退出，需重新打开。';

  @override
  String get exportDoneTitle => '导出完成';

  @override
  String exportSavedAs(String name) {
    return '备份文件已保存：$name';
  }

  @override
  String get exportShareWarning => '备份可能包含账号、密码等敏感信息，分享时请注意。';

  @override
  String get share => '分享';

  @override
  String get exporting => '正在导出…';

  @override
  String get exportFailed => '导出失败，请重试';

  @override
  String get shareFailed => '分享失败';

  @override
  String get reload => '重新加载';

  @override
  String get catpawTimeoutError => '连接 catpaw 服务超时，请稍后重试';

  @override
  String get catpawUnreachable => '无法连接 catpaw 服务，请确认本地服务已启动';

  @override
  String get catpawBadCertificate => 'catpaw 服务证书校验失败';

  @override
  String httpError(int code, String message) {
    return 'HTTP $code：$message';
  }

  @override
  String get playerLongPressSpeedAdjust => '长按滑动调节倍速';

  @override
  String get playerLongPressSpeedAdjustSub => '关闭后长按仅使用固定倍速';

  @override
  String get playerMdkNote => 'MDK 只随 arm64-v8a 版本提供；在其他设备上播放器页会回退到 Exo 并提示原因。';

  @override
  String get playerIosAvplayerNote =>
      'AVPlayer 使用 Apple VideoToolbox 系统硬件解码，原生支持 iOS 系统画中画（PiP）、AirPlay 隔空投屏与低功耗播放（适合 HLS / MP4）。';

  @override
  String get playerIosMpvNote =>
      'MPV 内核基于 libmpv + FFmpeg + Metal/MoltenVK（gpu-next），支持 VideoToolbox 硬解、杜比视界/HDR 色调映射、MKV/ASS 特效字幕与网盘高码率直连，但暂不支持 iOS 系统画中画。';

  @override
  String get playerIosVlcNote =>
      'VLC 内核基于 FFmpeg / libvlc，支持 MKV、FLV、AVI、内封 ASS 字幕等更多格式与软硬解切换，但暂不支持 iOS 系统画中画。';

  @override
  String get playerHwDecodeIosAvSub =>
      'AVPlayer 始终启用系统硬件解码；此开关对 MPV 与 VLC 内核生效';

  @override
  String get playerAutoPipIosVlcSub => 'iOS 系统画中画仅在 AVPlayer 内核下可用';

  @override
  String get playerSubtitleFontHintIos => 'iOS 系统字体名（如 PingFang SC）';

  @override
  String get playerSubtitleNoteIos =>
      '支持内封字幕轨及外挂 SRT、WebVTT、ASS/SSA（可在播放页从「文件」或 URL 导入）。';

  @override
  String get playerReloadNote => '在播放页里切换播放内核或硬件加速后，会从当前进度重新载入视频。';

  @override
  String get searchSiteManager => '站点搜索管理';

  @override
  String get searchSwitchLayout => '切换布局';

  @override
  String get searchLayoutList => '列表';

  @override
  String get searchLayoutTop => '顶部站点分类';

  @override
  String get searchLayoutLeft => '左侧站点分类';

  @override
  String get searchHistory => '搜索历史';

  @override
  String get searchHistoryClear => '清空搜索历史';

  @override
  String get searchHistoryClearConfirm => '确定清空全部搜索历史吗？';

  @override
  String get searchSearching => '搜索中…';

  @override
  String searchFailed(String error) {
    return '搜索失败：$error';
  }

  @override
  String get searchTwoColumns => '双列视图';

  @override
  String get searchOneColumn => '单列视图';

  @override
  String get searchNoSites => '暂无可用站点，请先添加订阅';

  @override
  String searchSiteTab(String site, int count) {
    return '$site ($count)';
  }
}
