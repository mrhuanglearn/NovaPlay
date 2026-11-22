import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// A media resource found on a web page.
class SniffedResource {
  const SniffedResource({required this.url, required this.kind, this.headers = const {}, this.title});

  factory SniffedResource.fromReport(Map<String, dynamic> j) => SniffedResource(
        url: '${j['url']}',
        kind: '${j['kind'] ?? 'file'}',
        title: j['title'] as String?,
        headers: {
          if (j['referer'] != null) 'Referer': '${j['referer']}',
          if (j['userAgent'] != null) 'User-Agent': '${j['userAgent']}',
        },
      );

  final String url;
  final String kind; // hls | dash | file
  final Map<String, String> headers;
  final String? title;
}

/// Web video sniffer (changelog 1.1.1: "web video sniffing on all platforms").
///
/// OBSERVED: asset `assets/scripts/sniffer_inject.js`, JS handler name `snifferReport`, route `/sniffer/web`,
/// strings "Sniffed resource", "Sniffed video", `SnifferResource(`, settings provider `snifferSettings`, and the
/// call `window.__uzvSnifferScan && window.__uzvSnifferScan();` from the Dart side.
class SnifferService {
  String? _script;

  Future<String> _loadScript() async => _script ??= await rootBundle.loadString('assets/scripts/sniffer_inject.js');

  static final _resourceMediaRe = RegExp(
    r'(?:\.(m3u8|mp4|mkv|flv|mpd|webm|mov)(?:[?&#/]|$)|[?&](?:type|format|ext)=(m3u8|mp4|flv|mpd)(?:[&#]|$))',
    caseSensitive: false,
  );
  static final _nonStreamExtRe = RegExp(r'\.(ts|js|mjs|css|html?|json|xml|jpe?g|png|gif|webp|svg|ico|woff2?|ttf)(\?|#|$)',
      caseSensitive: false);

  /// Returns true if [rawUrl] observed in WebView resource loading looks like a playable stream manifest or file.
  static bool looksLikePlayableResourceUrl(String rawUrl) {
    final u = rawUrl.trim();
    if (u.isEmpty || (!u.startsWith('http://') && !u.startsWith('https://'))) return false;
    if (_nonStreamExtRe.hasMatch(u)) return false;
    return _resourceMediaRe.hasMatch(u);
  }

  /// Settings for the interactive sniffer page / `/website` config page / headless run.
  ///
  /// `sharedCookiesEnabled`, `domStorageEnabled`, `databaseEnabled`, and `thirdPartyCookiesEnabled` ensure cookies
  /// and login state set inside `/website` or cloud-drive QR pages on iOS `WKWebView` sync immediately to persistent
  /// `HTTPCookieStorage.shared` rather than remaining only in `WebKit.Networking`'s volatile RAM cache on force-quit.
  InAppWebViewSettings buildWebViewSettings({String? userAgent}) => InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        sharedCookiesEnabled: true,
        thirdPartyCookiesEnabled: true,
        allowsInlineMediaPlayback: true,
        mediaPlaybackRequiresUserGesture: false,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        useOnLoadResource: true,
        userAgent: (userAgent != null && userAgent.trim().isNotEmpty) ? userAgent.trim() : null,
      );

  InAppWebViewSettings get webViewSettings => buildWebViewSettings();

  /// Registers the report handler and the injected script on [controller]. Returns a stream of resources.
  Future<Stream<SniffedResource>> attach(InAppWebViewController controller) async {
    late final StreamController<SniffedResource> out;
    out = StreamController<SniffedResource>.broadcast(onCancel: () {
      if (!out.isClosed) unawaited(out.close());
    });
    controller.addJavaScriptHandler(
      handlerName: 'snifferReport',
      callback: (args) {
        if (args.isEmpty || out.isClosed) return;
        final report = args.first is String ? jsonDecode(args.first as String) : args.first;
        if (report is Map) out.add(SniffedResource.fromReport(report.cast<String, dynamic>()));
      },
    );
    await controller.addUserScript(
      userScript: UserScript(
        source: await _loadScript(),
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: false,
      ),
    );
    return out.stream;
  }

  Future<void> rescan(InAppWebViewController c) => c.evaluateJavascript(source: 'window.__uzvSnifferScan && window.__uzvSnifferScan();');

  /// Loads [pageUrl] in a headless WebView and returns the first media URL it requests (or null on timeout).
  Future<SniffedResource?> sniffFirstVideo(String pageUrl,
      {Map<String, String> headers = const {}, Duration timeout = const Duration(seconds: 20)}) async {
    final found = Completer<SniffedResource?>();
    final script = await _loadScript();
    String? customUa;
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == 'user-agent' && e.value.trim().isNotEmpty) {
        customUa = e.value.trim();
        break;
      }
    }
    final view = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(pageUrl), headers: headers),
      initialSettings: buildWebViewSettings(userAgent: customUa),
      initialUserScripts: UnmodifiableListView([
        UserScript(
          source: script,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: false,
        ),
      ]),
      onWebViewCreated: (c) => c.addJavaScriptHandler(
        handlerName: 'snifferReport',
        callback: (args) {
          if (args.isEmpty || found.isCompleted) return;
          final raw = args.first is String ? jsonDecode(args.first as String) : args.first;
          if (raw is Map) found.complete(SniffedResource.fromReport(raw.cast<String, dynamic>()));
        },
      ),
      onLoadResource: (c, res) {
        final url = res.url?.toString() ?? '';
        if (!found.isCompleted && looksLikePlayableResourceUrl(url)) {
          final lower = url.toLowerCase();
          found.complete(SniffedResource(
            url: url,
            kind: lower.contains('m3u8') ? 'hls' : (lower.contains('mpd') ? 'dash' : 'file'),
            headers: {'Referer': pageUrl, if (customUa != null) 'User-Agent': customUa},
          ));
        }
      },
    );
    await view.run();
    try {
      return await found.future.timeout(timeout, onTimeout: () => null);
    } finally {
      await view.dispose();
    }
  }
}
