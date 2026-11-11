import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/json_store.dart';

// 主题设置 → 字体, OBSERVED on the original (2026-11-09, with the user's consent a test font was imported, selected and
// deleted again; docs/ui-ref/original/orig_font_*.png):
// - 导入字体 opens the system picker limited to font files. The copy is named after the md5 of its content plus its
//   extension (uzData/Data/Fonts/d44217533b8fc84194352d26a2db3cec.otf); the same file again gives 该字体已存在.
// - The new row shows the file name without its extension, drawn in the font itself, and is not selected.
// - Choosing it switches the whole app's text to it (glyphs it lacks, e.g. Chinese, come from the system font); this
//   survives a restart (the original preloads fonts at start: "2/5 开始预加载字体...").
// - × asks 删除字体 / 确定删除该字体吗？; deleting the chosen font goes back to 默认 and removes the file.
// - settings.hive keeps `fontSettings` = {selected id (null = 默认), fonts: [{id, name, file name, family
//   "uzn_user_<md5>"}]}.

/// One imported font. [id] is the md5 of the file's content.
class UserFont {
  const UserFont({required this.id, required this.name, required this.fileName});

  final String id;

  /// The picked file's name without its extension (OBSERVED "Comfortaa-Regular").
  final String name;

  /// `<id>.<ext>` in the fonts folder.
  final String fileName;

  /// The family the font is registered under (the original's is `uzn_user_<md5>`).
  String get family => 'uzv_user_$id';

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'file': fileName};

  static UserFont? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], name = json['name'], file = json['file'];
    if (id is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(id) || name is! String || file is! String) return null;
    if (file != p.basename(file) || !file.startsWith(id)) return null; // only files in our folder, named by the id
    return UserFont(id: id, name: name, fileName: file);
  }
}

/// The fonts card: the imported fonts and the chosen one (null = 默认). Kept in `fonts.json`.
class FontSettings {
  const FontSettings({this.selectedId, this.fonts = const []});

  final String? selectedId;
  final List<UserFont> fonts;

  UserFont? get selected => fonts.where((f) => f.id == selectedId).firstOrNull;

  /// The family the app's text uses; null = the platform font (默认).
  String? get fontFamily => selected?.family;

  Map<String, dynamic> toJson() => {
        'selected': selected?.id,
        'fonts': [for (final f in fonts) f.toJson()]
      };

  /// Malformed entries are dropped; a selection that names no listed font means 默认.
  factory FontSettings.fromJson(Object? json) {
    if (json is! Map) return const FontSettings();
    final raw = json['fonts'];
    final fonts = <UserFont>[];
    for (final f in raw is List ? raw : const []) {
      final font = UserFont.fromJson(f);
      if (font != null && fonts.every((x) => x.id != font.id)) fonts.add(font);
    }
    final selected = json['selected'];
    return FontSettings(
      selectedId: fonts.any((f) => f.id == selected) ? selected as String : null,
      fonts: List.unmodifiable(fonts),
    );
  }
}

enum FontImportResult { imported, exists, failed }

/// The font files and the engine's font registry. One instance per process: a family can be registered only once
/// (Flutter's FontLoader cannot load twice, the original's "FontLoader is already loaded").
class FontFiles {
  FontFiles({Future<Directory> Function()? dir}) : _dir = dir ?? _defaultDir;

  final Future<Directory> Function() _dir;
  final _registered = <String>{};

  static Future<Directory> _defaultDir() async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'fonts'));

  Future<File> _file(String fileName) async => File(p.join((await _dir()).path, fileName));

  Future<void> write(String fileName, Uint8List bytes) async {
    final f = await _file(fileName);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
  }

  Future<Uint8List?> read(String fileName) async {
    final f = await _file(fileName);
    return await f.exists() ? f.readAsBytes() : null;
  }

  Future<void> delete(String fileName) async {
    final f = await _file(fileName);
    if (await f.exists()) await f.delete();
  }

  /// Hands [bytes] to the engine under [family].
  Future<void> register(String family, Uint8List bytes) async {
    final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
  }

  /// Registers [font] unless that was done already. False when its file is missing or cannot be loaded.
  Future<bool> ensureLoaded(UserFont font) async {
    if (_registered.contains(font.family)) return true;
    try {
      final bytes = await read(font.fileName);
      if (bytes == null) return false;
      await register(font.family, bytes);
      _registered.add(font.family);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// TrueType (00 01 00 00 / "true"), OpenType CFF ("OTTO") and collections ("ttcf").
bool looksLikeFont(Uint8List bytes) {
  if (bytes.length < 12) return false;
  final head = String.fromCharCodes(bytes.sublist(0, 4));
  return (bytes[0] == 0 && bytes[1] == 1 && bytes[2] == 0 && bytes[3] == 0) ||
      head == 'true' ||
      head == 'OTTO' ||
      head == 'ttcf';
}

const fontExtensions = ['ttf', 'otf'];

/// Startup (before the first frame, like the original's preload): registers every font; one whose file is gone
/// (backup restore and WebDAV carry no font files; 重置应用 wipes the folder) or cannot be loaded is dropped, and
/// the choice goes back to 默认 if it was that one.
Future<FontSettings> restoreFonts(FontSettings settings, FontFiles files) async {
  final kept = <UserFont>[];
  for (final f in settings.fonts) {
    if (await files.ensureLoaded(f)) kept.add(f);
  }
  if (kept.length == settings.fonts.length) return settings;
  return FontSettings(
    selectedId: kept.any((f) => f.id == settings.selectedId) ? settings.selectedId : null,
    fonts: List.unmodifiable(kept),
  );
}

final fontsStoreProvider = Provider((ref) => JsonStore('fonts.json'));
final fontFilesProvider = Provider((ref) => FontFiles());

/// What `main()` restored before `runApp`.
final initialFontSettingsProvider = Provider<FontSettings>((ref) => const FontSettings());

typedef PickedFont = ({String name, Uint8List bytes});

/// The system picker limited to font files (OBSERVED: other files are greyed out).
final fontPickerProvider = Provider<Future<PickedFont?> Function()>((ref) => () async {
      final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: fontExtensions);
      if (f == null) return null;
      return (name: f.name, bytes: await f.readAsBytes());
    });

final fontSettingsProvider = NotifierProvider<FontSettingsNotifier, FontSettings>(FontSettingsNotifier.new);

class FontSettingsNotifier extends Notifier<FontSettings> {
  @override
  FontSettings build() => ref.watch(initialFontSettingsProvider);

  Future<void> _save(FontSettings next) async {
    state = next;
    await ref.read(fontsStoreProvider).write(next.toJson());
  }

  /// null = 默认.
  Future<void> select(String? id) async {
    if (id == state.selectedId || (id != null && state.fonts.every((f) => f.id != id))) return;
    await _save(FontSettings(selectedId: id, fonts: state.fonts));
  }

  /// 导入字体: copies the file as `<md5>.<ext>` and registers it before the row appears, so the row is drawn in it.
  Future<FontImportResult> importFont(String fileName, Uint8List bytes) async {
    final ext = p.extension(fileName).toLowerCase();
    if (!fontExtensions.contains(ext.replaceFirst('.', '')) || !looksLikeFont(bytes)) return FontImportResult.failed;
    final id = md5.convert(bytes).toString();
    if (state.fonts.any((f) => f.id == id)) return FontImportResult.exists;
    final font = UserFont(id: id, name: p.basenameWithoutExtension(fileName), fileName: '$id$ext');
    final files = ref.read(fontFilesProvider);
    try {
      await files.write(font.fileName, bytes);
    } catch (_) {
      return FontImportResult.failed;
    }
    if (!await files.ensureLoaded(font)) {
      try {
        await files.delete(font.fileName);
      } catch (_) {
        // Nothing to undo.
      }
      return FontImportResult.failed;
    }
    await _save(FontSettings(selectedId: state.selectedId, fonts: List.unmodifiable([...state.fonts, font])));
    return FontImportResult.imported;
  }

  /// Removes the font and its file; the chosen font goes back to 默认. (The engine keeps the family until the process
  /// ends; nothing uses it any more.)
  Future<void> delete(UserFont font) async {
    await _save(FontSettings(
      selectedId: state.selectedId == font.id ? null : state.selectedId,
      fonts: List.unmodifiable(state.fonts.where((f) => f.id != font.id)),
    ));
    try {
      await ref.read(fontFilesProvider).delete(font.fileName);
    } catch (_) {
      // Already gone; the entry is what matters.
    }
  }
}
