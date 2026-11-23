import '../../core/json_store.dart';
import 'spider_api.dart';

/// Browser-verified credentials (cookies + exact WebView User-Agent + resolved origin) for a challenge-gated site.
class SiteAuthEntry {
  const SiteAuthEntry({
    required this.siteKey,
    required this.origin,
    required this.cookie,
    required this.userAgent,
    required this.updatedAt,
  });

  factory SiteAuthEntry.fromJson(String fallbackKey, Map<String, dynamic> j) => SiteAuthEntry(
        siteKey: (j['siteKey'] as String?)?.trim().isNotEmpty == true ? (j['siteKey'] as String).trim() : fallbackKey,
        origin: '${j['origin'] ?? ''}'.trim().replaceAll(RegExp(r'/+$'), ''),
        cookie: '${j['cookie'] ?? ''}'.trim(),
        userAgent: '${j['userAgent'] ?? ''}'.trim(),
        updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
      );

  final String siteKey;
  final String origin;
  final String cookie;
  final String userAgent;
  final int updatedAt;

  Map<String, Object?> toJson() => {
        'siteKey': siteKey,
        'origin': origin,
        'cookie': cookie,
        'userAgent': userAgent,
        'updatedAt': updatedAt,
      };
}

/// Persists verified site cookies + User-Agent strings across restarts (`site_verifications.json`).
class SiteAuthRepository {
  SiteAuthRepository({JsonStore? store}) : _store = store ?? JsonStore('site_verifications.json');

  final JsonStore _store;

  Future<Map<String, SiteAuthEntry>> all() async {
    final raw = await _store.read<Map<String, dynamic>>(const {});
    final out = <String, SiteAuthEntry>{};
    for (final e in raw.entries) {
      if (e.value case final Map m) {
        final key = e.key.trim().toLowerCase();
        if (key.isEmpty) continue;
        final parsed = SiteAuthEntry.fromJson(key, m.cast<String, dynamic>());
        if (parsed.origin.isNotEmpty) out[key] = parsed;
      }
    }
    return out;
  }

  Future<SiteAuthEntry?> get(String siteKey) async => (await all())[siteKey.trim().toLowerCase()];

  Future<void> save(SiteAuthEntry entry) async {
    final key = entry.siteKey.trim().toLowerCase();
    if (key.isEmpty) return;
    await _store.update<Map<String, dynamic>>(const {}, (prev) => {...prev, key: entry.toJson()});
  }

  Future<void> remove(String siteKey) async {
    final key = siteKey.trim().toLowerCase();
    await _store.update<Map<String, dynamic>>(const {}, (prev) {
      final next = Map<String, dynamic>.of(prev)..remove(key);
      return next;
    });
  }
}

/// Describes a 403 / WAF / PoW challenge that can be completed by the user in the visible in-app browser.
class SiteVerifyChallenge {
  const SiteVerifyChallenge({
    required this.siteKey,
    required this.siteName,
    required this.verifyUrl,
  });

  final String siteKey;
  final String siteName;
  final String verifyUrl;
}

const _knownVerifyUrls = <String, String>{
  'libvio': 'https://libvio.host/',
};

final _challengeSignalRe = RegExp(
  r'\bHTTP 403\b|status code 403|BROWSER_VERIFY_REQUIRED|Browser Verification Required|命中防护|异常拦截页面|安全验证|访问验证',
  caseSensitive: false,
);
final _gatewayFailRe = RegExp(r'\bHTTP (?:502|503)\b|status code (?:502|503)', caseSensitive: false);
final _embeddedUrlRe = RegExp(r'''https?://[^\s)"'<>]+''', caseSensitive: false);

bool _isIgnoredDocOrLoopbackHost(String host) {
  final h = host.toLowerCase();
  return h.isEmpty ||
      h == 'localhost' ||
      h == '127.0.0.1' ||
      h == '0.0.0.0' ||
      h == '::1' ||
      h == '[::1]' ||
      h == 'developer.mozilla.org';
}

String? _usableOrigin(String? rawUrl, {String? ignoreHost}) {
  if (rawUrl == null || rawUrl.trim().isEmpty) return null;
  final uri = Uri.tryParse(rawUrl.trim());
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return null;
  if (_isIgnoredDocOrLoopbackHost(uri.host)) return null;
  if (ignoreHost != null && ignoreHost.isNotEmpty && uri.host.toLowerCase() == ignoreHost.toLowerCase()) return null;
  return '${uri.scheme}://${uri.authority}/';
}

/// Returns a [SiteVerifyChallenge] when [error] indicates an upstream 403 / anti-bot challenge for [site].
SiteVerifyChallenge? detectSiteVerifyChallenge(
  Object error,
  SpiderSite? site, {
  String? subscriptionHubUrl,
  int? statusCode,
  Object? responseData,
}) {
  if (site == null) return null;
  final key = site.key.trim().toLowerCase();
  final bareKey = key.replaceFirst(RegExp(r'^nodejs_'), '');
  final hubHost = Uri.tryParse(subscriptionHubUrl ?? '')?.host;

  String? explicitVerifyUrl;
  var explicitChallengeCode = false;
  final bodyMessages = <String>[];
  if (responseData is Map) {
    if (responseData['verifyUrl'] is String) {
      explicitVerifyUrl = responseData['verifyUrl'] as String;
    }
    if (responseData['code'] == 'BROWSER_VERIFY_REQUIRED') {
      explicitChallengeCode = true;
    }
    for (final k in const ['message', 'error', 'msg']) {
      if (responseData[k] is String && (responseData[k] as String).trim().isNotEmpty) {
        bodyMessages.add((responseData[k] as String).trim());
      }
    }
  } else if (responseData is String && responseData.trim().isNotEmpty) {
    bodyMessages.add(responseData.trim());
  }
  final combinedMsg = [...bodyMessages, '$error'].join('\n');

  final knownUrl = _knownVerifyUrls[key] ?? _knownVerifyUrls[bareKey];
  final isChallenge = statusCode == 403 ||
      explicitChallengeCode ||
      _challengeSignalRe.hasMatch(combinedMsg) ||
      (knownUrl != null && (statusCode == 502 || statusCode == 503 || _gatewayFailRe.hasMatch(combinedMsg)));
  if (!isChallenge) return null;

  String? resolved = _usableOrigin(explicitVerifyUrl, ignoreHost: hubHost);
  if (resolved == null) {
    for (final src in [...bodyMessages, '$error']) {
      for (final m in _embeddedUrlRe.allMatches(src)) {
        resolved = _usableOrigin(m.group(0), ignoreHost: hubHost);
        if (resolved != null) break;
      }
      if (resolved != null) break;
    }
  }
  resolved ??= knownUrl ?? _usableOrigin(site.homeUrl, ignoreHost: hubHost);
  if (resolved == null) return null;

  return SiteVerifyChallenge(siteKey: site.key, siteName: site.name, verifyUrl: resolved);
}
