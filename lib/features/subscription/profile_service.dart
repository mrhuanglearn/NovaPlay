import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/json_store.dart';
import '../catpaw/dart_callback_server.dart';

/// Unwraps any accidental `{"ok": true, "code": 0, "data": ...}` envelope layers while preserving newer top-level site
/// keys (`quark`, `spider`, `guazi`, ...) merged on top of older inner layers.
({Object? value, bool changed}) _sanitizeWithFlag(Object? raw) {
  if (raw is! Map) return (value: raw, changed: false);
  final map = raw.cast<String, dynamic>();
  final isEnvelope = map['ok'] is bool && map['code'] is num && map.containsKey('data');
  if (isEnvelope) {
    final inner = _sanitizeWithFlag(map['data']).value;
    final base = inner is Map ? Map<String, dynamic>.of(inner.cast<String, dynamic>()) : <String, dynamic>{};
    final outer = <String, dynamic>{};
    for (final entry in map.entries) {
      final k = entry.key;
      if (k == 'ok' || k == 'code' || k == 'data' || k == 'error') continue;
      outer[k] = _sanitizeWithFlag(entry.value).value;
    }
    return (value: mergeProfileMaps(base, outer), changed: true);
  }
  var nestedChanged = false;
  final out = <String, dynamic>{};
  for (final entry in map.entries) {
    final v = entry.value;
    if (v is Map) {
      final child = _sanitizeWithFlag(v);
      if (child.changed) nestedChanged = true;
      out[entry.key] = child.value is Map
          ? Map<String, dynamic>.of((child.value as Map).cast<String, dynamic>())
          : child.value;
    } else {
      out[entry.key] = v;
    }
  }
  return (value: out, changed: nestedChanged);
}

Object? sanitizeSubscriptionProfile(Object? raw) => _sanitizeWithFlag(raw).value;

Map<String, dynamic> mergeProfileMaps(Map<String, dynamic> older, Map<String, dynamic> newer) {
  final out = Map<String, dynamic>.of(older);
  for (final entry in newer.entries) {
    final prevVal = out[entry.key];
    final nextVal = entry.value;
    if (prevVal is Map && nextVal is Map) {
      out[entry.key] = {
        ...prevVal.cast<String, dynamic>(),
        ...nextVal.cast<String, dynamic>(),
      };
    } else {
      out[entry.key] = nextVal;
    }
  }
  return out;
}

/// Manages subscription profile storage (`subscription_profiles.json`), Russian-doll envelope healing, in-memory
/// caching for `queryProfile`, and atomic sidecar files (`subscription_profiles/<key>.json`) passed to Node workers.
class SubscriptionProfileService {
  SubscriptionProfileService(this.store);

  final JsonStore store;

  int _syncedRev = -1;
  Map<String, dynamic> _cachedProfiles = {};

  Future<Map<String, dynamic>> _loadSanitizedMap() async {
    if (_syncedRev == store.revision) return _cachedProfiles;
    final rawAll = Map<String, dynamic>.of(await store.read<Map<String, dynamic>>(<String, dynamic>{}));
    var dirty = false;
    if (rawAll.containsKey('null') && rawAll['null'] == null) {
      rawAll.remove('null');
      dirty = true;
    }
    final cleaned = <String, dynamic>{};
    for (final entry in rawAll.entries) {
      final res = _sanitizeWithFlag(entry.value);
      if (res.changed) dirty = true;
      cleaned[entry.key] = res.value;
    }
    if (dirty) {
      await store.write(cleaned);
    }
    _cachedProfiles = cleaned;
    _syncedRev = store.revision;
    return _cachedProfiles;
  }

  Future<File?> _sidecarFile(String subKey) async {
    try {
      final baseDir = await store.resolveBaseDir();
      final safeSubName = subKey.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final dir = Directory(p.join(baseDir.path, 'subscription_profiles'));
      await dir.create(recursive: true);
      return File(p.join(dir.path, '$safeSubName.json'));
    } catch (_) {
      return null;
    }
  }

  /// Writes `<baseDir>/subscription_profiles/<subKey>.json` atomically (`tmp` + `rename`).
  Future<String?> writeSidecarFile(String subKey, Object? value, {bool onlyIfMissingOrNonNull = false}) async {
    final pf = await _sidecarFile(subKey);
    if (pf == null) return null;
    try {
      if (onlyIfMissingOrNonNull && await pf.exists() && value == null) {
        return pf.path;
      }
      final seed = value is Map ? value : (value ?? <String, dynamic>{});
      final tmp = File('${pf.path}.tmp');
      await tmp.writeAsString(jsonEncode(seed), flush: true);
      await tmp.rename(pf.path);
      return pf.path;
    } catch (_) {
      return null;
    }
  }

  /// Prepares the sidecar profile JSON file before starting a CatPaw worker and returns its path.
  Future<String?> prepareProfilePath(String subKey) async {
    try {
      final all = await _loadSanitizedMap();
      final entry = all[subKey] ?? all['default'];
      return await writeSidecarFile(subKey, entry, onlyIfMissingOrNonNull: true);
    } catch (_) {
      return null;
    }
  }

  Future<RawJsonResponse> queryProfile(String subKey, Map<String, dynamic> args) async {
    final all = await _loadSanitizedMap();
    final slot = args['name'];
    if (slot is String && slot.isNotEmpty && args.length == 1) {
      final scopedKey = all.containsKey('$subKey:$slot') ? '$subKey:$slot' : (all.containsKey(slot) ? slot : null);
      if (scopedKey != null) {
        return RawJsonResponse(all[scopedKey] ?? <String, dynamic>{});
      }
      return const RawJsonResponse(<String, dynamic>{});
    }
    final targetKey = all.containsKey(subKey)
        ? subKey
        : (subKey != 'default' && all.containsKey('default') ? 'default' : null);
    if (targetKey != null) {
      return RawJsonResponse(all[targetKey] ?? <String, dynamic>{});
    }
    return const RawJsonResponse(<String, dynamic>{});
  }

  Future<void> saveProfile(String subKey, Map<String, dynamic> args) async {
    final all = Map<String, dynamic>.of(await _loadSanitizedMap());
    final slot = args['name'];
    var updateSidecar = false;
    if (slot is String && slot.isNotEmpty && args.containsKey('profile') && args.length == 2) {
      all['$subKey:$slot'] = sanitizeSubscriptionProfile(args['profile']);
    } else if (args.length == 1 && args.containsKey('value')) {
      all[subKey] = sanitizeSubscriptionProfile(args['value']);
      updateSidecar = true;
    } else if (args.length == 1 && args.containsKey('profile')) {
      final inner = sanitizeSubscriptionProfile(args['profile']);
      final prev = all[subKey];
      if (inner is Map && inner.isNotEmpty && prev is Map) {
        all[subKey] = mergeProfileMaps(prev.cast<String, dynamic>(), inner.cast<String, dynamic>());
      } else {
        all[subKey] = inner;
      }
      updateSidecar = true;
    } else {
      final sanitizedIncoming = sanitizeSubscriptionProfile(Map<String, dynamic>.of(args));
      final prev = all[subKey];
      if (sanitizedIncoming is Map && sanitizedIncoming.isNotEmpty && prev is Map) {
        all[subKey] = mergeProfileMaps(prev.cast<String, dynamic>(), sanitizedIncoming.cast<String, dynamic>());
      } else {
        all[subKey] = sanitizedIncoming;
      }
      updateSidecar = true;
    }
    _cachedProfiles = all;
    await store.write(all);
    _syncedRev = store.revision;
    if (updateSidecar) {
      await writeSidecarFile(subKey, all[subKey]);
    }
  }
}
