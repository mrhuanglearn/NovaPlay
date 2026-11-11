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

  /// Settings for the interactive sniffer page / headless run.
  InAppWebViewSettings get webViewSettings => InAppWebViewSettings(
        javaScriptEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        useShouldInterceptRequest: true, // Android: lets us see every sub-resource request
        useOnLoadResource: true,
      );

  /// Registers the report handler and the injected script on [controller]. Returns a stream of resources.
  Future<Stream<SniffedResource>> attach(InAppWebViewController controller) async {
    final out = StreamController<SniffedResource>.broadcast();
    controller.addJavaScriptHandler(
      handlerName: 'snifferReport',
      callback: (args) {
        if (args.isEmpty) return;
        final report = args.first is String ? jsonDecode(args.first as String) : args.first;
        if (report is Map) out.add(SniffedResource.fromReport(report.cast<String, dynamic>()));
      },
    );
    await controller.addUserScript(
      userScript: UserScript(source: await _loadScript(), injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
    );
    return out.stream;
  }

  Future<void> rescan(InAppWebViewController c) => c.evaluateJavascript(source: 'window.__uzvSnifferScan && window.__uzvSnifferScan();');

  /// Loads [pageUrl] in a headless WebView and returns the first media URL it requests (or null on timeout).
  Future<SniffedResource?> sniffFirstVideo(String pageUrl,
      {Map<String, String> headers = const {}, Duration timeout = const Duration(seconds: 20)}) async {
    final found = Completer<SniffedResource?>();
    final script = await _loadScript();
    final view = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(pageUrl), headers: headers),
      initialSettings: webViewSettings,
      initialUserScripts: UnmodifiableListView([UserScript(source: script, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START)]),
      onWebViewCreated: (c) => c.addJavaScriptHandler(
        handlerName: 'snifferReport',
        callback: (args) {
          if (args.isEmpty || found.isCompleted) return;
          final r = args.first;
          if (r is Map) found.complete(SniffedResource.fromReport(r.cast<String, dynamic>()));
        },
      ),
      onLoadResource: (c, res) {
        final url = res.url?.toString() ?? '';
        if (!found.isCompleted && RegExp(r'\.(m3u8|mp4|mpd)(\?|$)', caseSensitive: false).hasMatch(url)) {
          found.complete(SniffedResource(url: url, kind: url.contains('.m3u8') ? 'hls' : 'file', headers: {'Referer': pageUrl}));
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
