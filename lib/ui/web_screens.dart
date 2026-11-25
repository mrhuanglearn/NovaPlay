import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/providers.dart';
import '../app/theme.dart';
import '../app/ui_hooks.dart';
import '../features/catpaw/site_auth.dart';
import '../features/player/playback_source.dart';
import '../features/sniffer/sniffer_service.dart';
import '../l10n/l10n.dart';
import 'widgets.dart';

final _mediaUrl = RegExp(r'\.(m3u8|mp4|mpd|flv)(\?|$)', caseSensitive: false);

/// CatPaw's `/website` 网盘凭证 page re-renders its horizontal drive rail on every pick, which resets the rail to the
/// start and hides the picked pill. Keep the active pill in view (horizontal only, so the page itself never jumps).
/// shortcut: works around the page (CatPaw websiteHtml.ts renderLogin), drop once the page scrolls the rail itself.
final _keepDrivePillVisible = UserScript(
  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
  source: r'''
(function () {
  if (!/\/website\/?$/.test(location.pathname)) return;
  var last = null;
  new MutationObserver(function () {
    var pill = document.querySelector('.drive-rail .drive-pill.active');
    if (!pill || pill === last) return;
    last = pill;
    var rail = pill.parentElement, r = rail.getBoundingClientRect(), p = pill.getBoundingClientRect();
    rail.scrollLeft += p.left - r.left - (r.width - p.width) / 2;
  }).observe(document.documentElement, { childList: true, subtree: true });
})();
''',
);

/// In-app browser. With [sniff] on (`/sniffer/web`) it collects the media streams the page requests and lets the user
/// play them; without it (`/website`, opened by a script's `openInternalWebview` or 403 site verification) it is a
/// plain page with the original's title bar (see `_plainBar`).
class WebScreen extends ConsumerStatefulWidget {
  const WebScreen({
    super.key,
    this.initialUrl = '',
    this.sniff = false,
    this.verifySiteKey,
    this.verifySiteName,
  });
  final String initialUrl;
  final bool sniff;
  final String? verifySiteKey;
  final String? verifySiteName;
  @override
  ConsumerState<WebScreen> createState() => _WebScreenState();
}

class _WebScreenState extends ConsumerState<WebScreen> {
  late final _url = TextEditingController(text: widget.initialUrl);
  InAppWebViewController? _web;
  StreamSubscription<SniffedResource>? _sub;
  Timer? _verifyTimer;
  bool _completingVerify = false;
  final _found = <SniffedResource>[];
  String _current = '';

  bool get _isVerifyMode => (widget.verifySiteKey ?? '').trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _current = widget.initialUrl;
    if (_isVerifyMode) {
      // Keep the WebView's native mobile User-Agent so TLS, navigator.platform, and Cookie match subsequent requests.
      _agentKey = 'default';
      _verifyTimer = Timer.periodic(
        const Duration(milliseconds: 900),
        (_) => _probeAndCompleteVerify(manual: false),
      );
    }
  }

  ProviderContainer? _container;

  bool get _isLocalAdminPage {
    if (widget.sniff || _isVerifyMode) return false;
    final u = Uri.tryParse(_current.isEmpty ? widget.initialUrl : _current);
    if (u == null) return false;
    return (u.host == '127.0.0.1' || u.host == 'localhost') &&
        (u.port == 9321 ||
            u.path.startsWith('/website') ||
            u.path.startsWith('/danmu') ||
            u.path.startsWith('/baseset') ||
            u.path.startsWith('/woniu-auth'));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container = ProviderScope.containerOf(context, listen: false);
  }

  @override
  void dispose() {
    _verifyTimer?.cancel();
    _sub?.cancel();
    _url.dispose();
    if (_isLocalAdminPage && _container != null) {
      final c = _container!;
      Future.microtask(() => reloadLiveCatalog(c));
    }
    super.dispose();
  }

  Future<void> _probeAndCompleteVerify({required bool manual}) async {
    final controller = _web;
    final siteKey = widget.verifySiteKey?.trim() ?? '';
    if (_completingVerify || controller == null || siteKey.isEmpty || !mounted) return;
    try {
      final rawEval = await controller.evaluateJavascript(source: r'''
        (function() {
          var html = document.documentElement ? document.documentElement.innerHTML : '';
          var sample = ((document.title || '') + '\n' + html.slice(0, 12000));
          var isChallenge = /__cdn_pow|cf-turnstile|_cf_chl_opt|acw_sc__v2|Just a moment|Checking your browser|^403\b|403 Forbidden|访问验证|安全验证|人机验证|正在进行安全检查/i.test(sample);
          var isLoginPage = /\/(?:user|account)\/(?:login|reg|signin)/i.test(location.pathname || '') || !!document.querySelector('#fm input[type="password"], form[action*="login" i] input[type="password"], .auth-form input[type="password"], .pan-lock-box');
          var hasLoginCookie = /(?:^|;\s*)user_id=(?!0\b)\w+/.test(document.cookie || '');
          var vodCount = document.querySelectorAll('a[href*="/detail/"], a[href*="/vod"], a[href*="/video/"], a[href*="/play/"], .stui-vodlist__box, .module-item, .myui-vodlist__box, .fed-list-item').length;
          return JSON.stringify({
            readyComplete: document.readyState === 'complete',
            isChallenge: isChallenge,
            isLoginPage: isLoginPage,
            hasLoginCookie: hasLoginCookie,
            vodCount: vodCount,
            docCookie: document.cookie || '',
            ua: navigator.userAgent || ''
          });
        })()
      ''');
      Map<String, dynamic> probe = const {};
      if (rawEval is String && rawEval.isNotEmpty) {
        final decoded = jsonDecode(rawEval);
        if (decoded is Map) probe = decoded.cast<String, dynamic>();
      } else if (rawEval is Map) {
        probe = rawEval.cast<String, dynamic>();
      }
      if (!manual) {
        final readyComplete = probe['readyComplete'] == true;
        final isChallenge = probe['isChallenge'] == true;
        final isLoginPage = probe['isLoginPage'] == true;
        final hasLoginCookie = probe['hasLoginCookie'] == true;
        final vodCount = (probe['vodCount'] as num?)?.toInt() ?? 0;
        if (!readyComplete || isChallenge || isLoginPage || (vodCount < 3 && !hasLoginCookie)) return;
      }
      _completingVerify = true;
      _verifyTimer?.cancel();
      final currentWebUri = await controller.getUrl() ?? WebUri(_current);
      final parsed = Uri.tryParse(currentWebUri.toString()) ?? Uri.parse(_current);
      final origin = '${parsed.scheme}://${parsed.authority}';
      final cookieMgr = CookieManager.instance();
      final mergedCookies = <String, String>{};
      final docCookie = ('${probe['docCookie'] ?? ''}').trim();
      if (docCookie.isNotEmpty) {
        for (final part in docCookie.split(';')) {
          final eq = part.indexOf('=');
          if (eq <= 0) continue;
          final k = part.substring(0, eq).trim();
          final v = part.substring(eq + 1).trim();
          if (k.isNotEmpty) mergedCookies[k] = v;
        }
      }
      for (final target in [WebUri('$origin/'), currentWebUri]) {
        final list = await cookieMgr.getCookies(url: target);
        for (final c in list) {
          if (c.name.isNotEmpty) mergedCookies[c.name] = '${c.value}';
        }
      }
      final cookieHeader = [for (final e in mergedCookies.entries) '${e.key}=${e.value}'].join('; ');
      final ua = ('${probe['ua'] ?? ''}').trim();
      await applyVerifiedSiteAuth(
        ref,
        SiteAuthEntry(
          siteKey: siteKey,
          origin: origin,
          cookie: cookieHeader,
          userAgent: ua,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      if (!mounted) return;
      showSuccessHud(context, '验证完成，正在刷新列表');
      Navigator.of(context).pop(true);
    } catch (_) {
      if (manual) _completingVerify = false;
    }
  }

  void _add(SniffedResource r) {
    if (_found.any((e) => e.url == r.url)) return;
    setState(() => _found.add(r));
  }

  /// A URL is opened as it is; anything else is searched for (INFERRED engine: Bing).
  void _go(String text) {
    var t = text.trim();
    if (t.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final looksLikeUrl = t.contains('://') || RegExp(r'^[\w-]+(\.[\w-]+)+(:\d+)?(/.*)?$').hasMatch(t);
    if (!looksLikeUrl) {
      t = 'https://www.bing.com/search?q=${Uri.encodeQueryComponent(t)}';
    } else if (!t.contains('://')) {
      t = 'https://$t';
    }
    setState(() => _current = t);
    _web?.loadUrl(urlRequest: URLRequest(url: WebUri(t)));
  }

  // OBSERVED User-Agent choices (默认 / iPhone / iPad / Android / 桌面 Chrome / 自定义...), 桌面 Chrome selected.
  static const _agents = <String, String?>{
    'default': null,
    'iphone':
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
    'ipad':
        'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
    'android':
        'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
    'desktop':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  };
  String _agentKey = 'desktop';
  String _customAgent = '';

  String? get _userAgent => _agentKey == 'custom' ? (_customAgent.isEmpty ? null : _customAgent) : _agents[_agentKey];

  Future<void> _chooseAgent() async {
    final l = context.l10n;
    final labels = {
      'default': l.webUaDefault,
      'iphone': 'iPhone',
      'ipad': 'iPad',
      'android': 'Android',
      'desktop': l.webUaDesktop,
      'custom': l.webUaCustom
    };
    final picked = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('User-Agent'),
        children: [
          RadioGroup<String>(
            groupValue: _agentKey,
            onChanged: (v) => Navigator.pop(c, v),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final e in labels.entries) RadioListTile<String>(value: e.key, title: Text(e.value), dense: true),
            ]),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    if (picked == 'custom') {
      final controller = TextEditingController(text: _customAgent);
      final text = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('User-Agent'),
          content: TextField(
              controller: controller,
              autofocus: true,
              maxLines: 3,
              decoration: InputDecoration(hintText: l.liveUserAgentHint)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: Text(l.cancel)),
            TextButton(onPressed: () => Navigator.pop(c, controller.text.trim()), child: Text(l.ok)),
          ],
        ),
      );
      controller.dispose();
      if (text == null) return;
      _customAgent = text;
    }
    setState(() => _agentKey = picked);
    final updatedSettings = ref.read(snifferServiceProvider).webViewSettings..userAgent = _userAgent ?? '';
    await _web?.setSettings(settings: updatedSettings);
    await _web?.reload();
  }

  Future<void> _play(SniffedResource r) async {
    try {
      await ref
          .read(playerLauncherProvider)
          .playSource(DirectPlaybackSource.single(title: r.title ?? _url.text, url: r.url, headers: r.headers));
    } catch (e) {
      showToast('$e');
    }
  }

  void _showFound() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: _found.isEmpty
            ? SizedBox(
                height: 220, child: EmptyState(icon: Icons.travel_explore, title: context.l10n.snifferNothingYet))
            : ListView(shrinkWrap: true, children: [
                for (final r in _found)
                  ListTile(
                    leading: Text(r.kind.toUpperCase()),
                    title: Text(r.url, maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () {
                      Navigator.pop(ctx);
                      _play(r);
                    },
                    trailing: IconButton(
                      icon: const Icon(Icons.copy),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: r.url));
                        showToast(context.l10n.copied);
                      },
                    ),
                  ),
              ]),
      ),
    );
  }

  /// The page's own title, shown by the plain page.
  String? _title;

  /// `/website` (a script's `openInternalWebview`). OBSERVED on the phone (UZN 1.1.7, 2026-11-10, 「设」配置 → 通用配置):
  /// a back arrow, the page's title centred, and a ⋯ menu with 重新加载 and a red 清空网页 Cookie; no address bar.
  PreferredSizeWidget _plainBar(BuildContext context) {
    final l = context.l10n;
    final verifyName = widget.verifySiteName?.trim();
    final barTitle = _isVerifyMode
        ? '验证 · ${verifyName != null && verifyName.isNotEmpty ? verifyName : (Uri.tryParse(_current)?.host ?? '')}'
        : (_title?.trim().isNotEmpty == true ? _title!.trim() : (Uri.tryParse(_current)?.host ?? ''));
    return AppBar(
      centerTitle: !_isVerifyMode,
      title: Text(barTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      actions: [
        if (_isVerifyMode)
          TextButton(
            onPressed: () => _probeAndCompleteVerify(manual: true),
            child: const Text('完成返回', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_horiz),
          position: PopupMenuPosition.under,
          onSelected: (v) async {
            switch (v) {
              case 'reload':
                await _web?.reload();
              case 'sniffer':
                if (context.mounted) {
                  context.pushReplacement(Uri(path: '/sniffer/web', queryParameters: {'url': _current}).toString());
                }
              case 'cookies':
                await CookieManager.instance().deleteAllCookies();
                showToast(l.webCookiesCleared);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
                value: 'reload',
                child: ListTile(dense: true, leading: const Icon(Icons.refresh), title: Text(l.reload))),
            if (_isVerifyMode)
              const PopupMenuItem(
                value: 'sniffer',
                child: ListTile(dense: true, leading: Icon(Icons.radar), title: Text('嗅探浏览器打开')),
              ),
            PopupMenuItem(
              value: 'cookies',
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.cookie_outlined, color: AppColors.danger),
                title: Text(l.webClearCookies, style: const TextStyle(color: AppColors.danger)),
              ),
            ),
          ],
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final sniffer = ref.read(snifferServiceProvider);
    final l = context.l10n;
    final c = AppColors.of(context);
    final settings = sniffer.webViewSettings..userAgent = _userAgent;
    if (!widget.sniff) {
      return Scaffold(
        appBar: _plainBar(context),
        body: _current.isEmpty
            ? const SizedBox.expand()
            : Column(children: [
                if (_isVerifyMode)
                  Container(
                    width: double.infinity,
                    color: c.accent.withValues(alpha: 0.12),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    child: Text(
                      '完成站点安全验证并加载出首页后将自动返回视频列表；也可点右上角「完成返回」',
                      style: TextStyle(fontSize: 12.5, color: c.label),
                    ),
                  ),
                Expanded(
                  child: InAppWebView(
                    initialUrlRequest: URLRequest(url: WebUri(_current)),
                    initialSettings: settings,
                    initialUserScripts: UnmodifiableListView([_keepDrivePillVisible]),
                    onWebViewCreated: (c) => _web = c,
                    onTitleChanged: (c, title) => setState(() => _title = title),
                    onLoadStop: (c, uri) {
                      if (uri != null) _current = uri.toString();
                      if (_isVerifyMode) _probeAndCompleteVerify(manual: false);
                    },
                  ),
                ),
              ]),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.sniff ? l.settingsSniffer : (Uri.tryParse(_current)?.host ?? ''),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        actions: [
          IconButton(tooltip: l.webReload, icon: const Icon(Icons.refresh), onPressed: () => _web?.reload()),
          if (widget.sniff)
            IconButton(
              tooltip: l.webSniffed,
              icon: Badge(
                  isLabelVisible: _found.isNotEmpty, label: Text('${_found.length}'), child: const Icon(Icons.radar)),
              onPressed: _showFound,
            ),
          IconButton(tooltip: 'User-Agent', icon: const Icon(Icons.smartphone), onPressed: _chooseAgent),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz),
            onSelected: (v) async {
              switch (v) {
                case 'clear':
                  setState(_found.clear);
                case 'external':
                  final u = _current.isEmpty ? _url.text.trim() : _current;
                  if (u.isNotEmpty) await launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
                case 'cookies':
                  await CookieManager.instance().deleteAllCookies();
                  showToast(l.webCookiesCleared);
              }
            },
            itemBuilder: (_) => [
              if (widget.sniff)
                PopupMenuItem(
                    value: 'clear',
                    child: ListTile(
                        dense: true,
                        leading: const Icon(Icons.cleaning_services_outlined),
                        title: Text(l.webClearList))),
              PopupMenuItem(
                  value: 'external',
                  child: ListTile(
                      dense: true, leading: const Icon(Icons.open_in_browser), title: Text(l.webOpenExternal))),
              PopupMenuItem(
                value: 'cookies',
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.cookie_outlined, color: AppColors.danger),
                  title: Text(l.webClearCookies, style: const TextStyle(color: AppColors.danger)),
                ),
              ),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  style: const TextStyle(fontSize: 14.5),
                  decoration: InputDecoration(
                    hintText: l.webSearchHint,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 11),
                    prefixIcon: Icon(Icons.travel_explore, size: 20, color: c.secondaryLabel),
                    suffixIcon: IconButton(
                      icon: Icon(Icons.content_paste, size: 18, color: c.secondaryLabel),
                      onPressed: () async {
                        final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
                        if (t != null && t.isNotEmpty) _url.text = t;
                      },
                    ),
                  ),
                  onSubmitted: _go,
                ),
              ),
              const SizedBox(width: 6),
              FilledButton(
                style: FilledButton.styleFrom(
                    shape: const StadiumBorder(),
                    minimumSize: const Size(54, 38),
                    padding: const EdgeInsets.symmetric(horizontal: 16)),
                onPressed: () => _go(_url.text),
                child: Text(l.webGo),
              ),
            ]),
          ),
        ),
      ),
      // OBSERVED: an empty black page until something is opened
      backgroundColor: Colors.black,
      body: _current.isEmpty
          ? const SizedBox.expand()
          : InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(_current)),
              initialSettings: settings,
              onWebViewCreated: (c) async {
                _web = c;
                if (widget.sniff) _sub = (await sniffer.attach(c)).listen(_add);
              },
              onLoadStop: (c, uri) {
                if (uri != null) _url.text = uri.toString();
                if (widget.sniff) sniffer.rescan(c);
              },
              onLoadResource: (c, res) {
                final u = res.url?.toString() ?? '';
                if (widget.sniff && _mediaUrl.hasMatch(u)) {
                  _add(SniffedResource(
                      url: u,
                      kind: u.toLowerCase().contains('.m3u8')
                          ? 'hls'
                          : (u.toLowerCase().contains('.mpd') ? 'dash' : 'file'),
                      headers: {'Referer': _current}));
                }
              },
            ),
    );
  }
}
