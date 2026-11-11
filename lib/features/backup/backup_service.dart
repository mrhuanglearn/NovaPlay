import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import '../../core/app_version.dart';
import '../../core/json_store.dart';
import '../../core/restore_error.dart';
import '../../services/webdav_sync.dart';

/// One choice on the original's 选择数据项并导出 sheet and the documents behind it. Groups and names follow the original
/// (用户数据 / 订阅与弹幕服务 / 偏好设置); 追剧, 弹幕匹配 and 账号 are this project's additions. Not reproduced: catpaw
/// 实例数据 (the runtime's own files), 搜索历史 and 站点偏好 (not stored here), 自定义字体文件.
class BackupItem {
  const BackupItem(this.key, this.group, this.files, {this.sensitive = false, this.byDefault = true});
  final String key;
  final String group; // user | subscriptions | preferences
  final List<String> files;

  /// Holds passwords, tokens or keys (the sheet then shows the plaintext warning).
  final bool sensitive;
  final bool byDefault;
}

const backupItems = <BackupItem>[
  BackupItem('history', 'user', ['history.json']),
  BackupItem('favorites', 'user', ['favorites.json', 'auto_sync_favorites.json']),
  BackupItem('progress', 'user', ['play_progress.json']),
  BackupItem('lastEpisode', 'user', ['last_episode.json']),
  BackupItem('tmdbRefs', 'user', ['tmdb_refs.json']),
  BackupItem('headTail', 'user', ['video_head_tail.json']),
  BackupItem('tracking', 'user', ['tracking.json']),
  BackupItem('danmuRefs', 'user', ['danmu_refs.json']),
  BackupItem('live', 'user', ['live_sources.json', 'live_preferences.json']),
  BackupItem('subscriptions', 'subscriptions', ['subscriptions.json', 'subscription_profiles.json'], sensitive: true),
  BackupItem('appSettings', 'preferences',
      ['settings.json', 'player_config.json', 'tmdb_settings.json', 'danmu_service_config.json'],
      sensitive: true),
  BackupItem('accounts', 'preferences', ['emby_accounts.json', 'webdav_config.json'],
      sensitive: true, byDefault: false),
];

/// Name of an exported backup (OBSERVED in the original: uzn-backup-20261109-055524.zip).
String backupFileName(DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'novaplay-backup-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}.zip';
}

/// Every document a backup may restore; anything else in an archive is ignored.
final backupFiles = {for (final i in backupItems) ...i.files, ...syncedDocuments};

/// Whole-app backup as one JSON document: every file in [syncedDocuments] that exists.
///
/// The original's backup format is not known (only the route `/settings/backup` and the list of synced files were
/// observed), so this is the project's own: `{"format":"uzv-reimpl-backup","version":1,"createdAt":ms,"documents":{file:json}}`.
class BackupService {
  BackupService({JsonStore Function(String file)? storeFor}) : _storeFor = storeFor ?? JsonStore.new;
  final JsonStore Function(String) _storeFor;

  static const format = 'uzv-reimpl-backup';

  /// The zip written by 选择数据项并导出: `manifest.json` plus one JSON file per document of the chosen [items].
  Future<List<int>> exportZip(Iterable<String> items, {DateTime? now}) async {
    final keys = items.toSet();
    final archive = Archive();
    final files = <String>[];
    for (final item in backupItems.where((i) => keys.contains(i.key))) {
      for (final file in item.files) {
        final doc = await _storeFor(file).read<Object?>(null);
        if (doc == null) continue;
        final bytes = utf8.encode(const JsonEncoder.withIndent(' ').convert(doc));
        archive.addFile(ArchiveFile(file, bytes.length, bytes));
        files.add(file);
      }
    }
    final manifest = utf8.encode(jsonEncode({
      'format': format,
      'version': 2,
      'createdAt': (now ?? DateTime.now()).millisecondsSinceEpoch,
      // Shown as 来源版本 when the backup is restored (OBSERVED in the original's sheet: 来源版本：v1.1.13（android）).
      'appVersion': appVersion,
      'platform': Platform.operatingSystem,
      'items': [
        for (final i in backupItems)
          if (keys.contains(i.key)) i.key
      ],
      'files': files,
    }));
    archive.addFile(ArchiveFile('manifest.json', manifest.length, manifest));
    return ZipEncoder().encode(archive);
  }

  /// Reads a zip from [exportZip] or a JSON backup from [export] without writing anything (选择备份文件恢复 shows
  /// what is in it first). Unknown file names and documents that are not JSON are left out, so a crafted backup cannot
  /// write arbitrary files. Throws [FormatException] for something that is not a backup.
  BackupContents read(List<int> bytes) {
    if (bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B) return _readZip(bytes);
    return _readJson(utf8.decode(bytes, allowMalformed: true));
  }

  BackupContents _readZip(List<int> bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('not a backup file');
    }
    final manifest = archive.findFile('manifest.json');
    if (manifest == null) throw const FormatException('not a backup file');
    final Object? meta;
    try {
      meta = jsonDecode(utf8.decode(manifest.content));
    } catch (_) {
      throw const FormatException('not a backup file');
    }
    if (meta is! Map || meta['format'] != format) throw const FormatException('not a backup file');
    final docs = <String, Object?>{};
    for (final entry in archive.files) {
      // Names are matched exactly against the known documents: no paths, so nothing outside the data folder is written.
      if (!entry.isFile || !backupFiles.contains(entry.name)) continue;
      try {
        docs[entry.name] = jsonDecode(utf8.decode(entry.content));
      } catch (_) {
        continue;
      }
    }
    return BackupContents._(docs, meta);
  }

  BackupContents _readJson(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const FormatException('not a backup file');
    }
    if (decoded is! Map || decoded['format'] != format || decoded['documents'] is! Map) {
      throw const FormatException('not a backup file');
    }
    final docs = (decoded['documents'] as Map).cast<String, Object?>();
    return BackupContents._({
      for (final file in syncedDocuments)
        if (docs.containsKey(file)) file: docs[file]
    }, decoded);
  }

  /// Writes the documents of the chosen [items] (keys of [backupItems]). Returns the restored file names. Everything
  /// was read and checked by [read]; a failed write is a [RestoreWriteException] (the earlier files are replaced).
  Future<List<String>> restore(BackupContents contents, Iterable<String> items) async {
    final files = {for (final i in backupItems.where((i) => items.contains(i.key))) ...i.files};
    final restored = <String>[];
    for (final MapEntry(key: file, value: doc) in contents.documents.entries) {
      if (!files.contains(file)) continue;
      try {
        await _storeFor(file).write(doc);
      } catch (e) {
        throw RestoreWriteException(file, e);
      }
      restored.add(file);
    }
    return restored;
  }

  /// Everything in a zip or JSON backup. Throws like [read] and [restore].
  Future<List<String>> importBytes(List<int> bytes) async {
    final contents = read(bytes);
    return restore(contents, contents.items);
  }

  Future<String> export() async {
    final docs = <String, Object?>{};
    for (final file in syncedDocuments) {
      final doc = await _storeFor(file).read<Object?>(null);
      if (doc != null) docs[file] = doc;
    }
    return const JsonEncoder.withIndent(' ').convert({
      'format': format,
      'version': 1,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'documents': docs,
    });
  }

  /// Restores everything in a JSON backup from [export].
  Future<List<String>> import(String text) => importBytes(utf8.encode(text));
}

/// What [BackupService.read] found in a backup.
class BackupContents {
  BackupContents._(this.documents, Map<dynamic, dynamic> meta)
      : createdAt = meta['createdAt'] is int ? DateTime.fromMillisecondsSinceEpoch(meta['createdAt'] as int) : null,
        appVersion = meta['appVersion'] is String ? meta['appVersion'] as String : null,
        platform = meta['platform'] is String ? meta['platform'] as String : null;

  /// For tests and callers that build contents themselves.
  BackupContents(this.documents, {this.createdAt, this.appVersion, this.platform});

  /// Known documents by file name, in the order they are written.
  final Map<String, Object?> documents;
  final DateTime? createdAt;

  /// Absent in backups written before 2026-11-09 and in JSON backups.
  final String? appVersion;
  final String? platform;

  /// Keys of the [backupItems] that have at least one document here, in the sheet's order.
  List<String> get items => [
        for (final i in backupItems)
          if (i.files.any(documents.containsKey)) i.key
      ];
}
