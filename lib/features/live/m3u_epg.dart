import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

/// IPTV support (changelog 1.1.7): M3U playlists, channel groups, XMLTV EPG.
class LiveChannel {
  const LiveChannel({required this.name, required this.url, this.group, this.logo, this.tvgId, this.tvgName});
  final String name;
  final String url;
  final String? group;
  final String? logo;
  final String? tvgId;
  final String? tvgName;
}

final _attr = RegExp(r'([A-Za-z0-9_-]+)="([^"]*)"');

/// The guide a playlist names in its header (`#EXTM3U x-tvg-url="…"` or `url-tvg="…"`; the first of a comma list).
String? m3uGuideUrl(String text) {
  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (!line.startsWith('#EXTM3U')) return null;
    final attrs = {for (final m in _attr.allMatches(line)) m.group(1)!.toLowerCase(): m.group(2)!};
    final v = (attrs['x-tvg-url'] ?? attrs['url-tvg'] ?? '').split(',').first.trim();
    return v.isEmpty ? null : v;
  }
  return null;
}

List<LiveChannel> parseM3u(String text) {
  final out = <LiveChannel>[];
  Map<String, String> pending = {};
  String? pendingName;
  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#EXTM3U')) continue;
    if (line.startsWith('#EXTINF')) {
      pending = {for (final m in _attr.allMatches(line)) m.group(1)!.toLowerCase(): m.group(2)!};
      final comma = line.lastIndexOf(',');
      pendingName = comma >= 0 ? line.substring(comma + 1).trim() : null;
    } else if (!line.startsWith('#')) {
      final name = (pendingName?.isNotEmpty ?? false) ? pendingName! : (pending['tvg-name'] ?? line);
      out.add(LiveChannel(
        name: name,
        url: line,
        group: pending['group-title'],
        logo: pending['tvg-logo'],
        tvgId: pending['tvg-id'],
        tvgName: pending['tvg-name'],
      ));
      pending = {};
      pendingName = null;
    }
  }
  return out;
}

class EpgEntry {
  const EpgEntry({required this.channelId, required this.start, required this.stop, required this.title, this.description});
  final String channelId;
  final DateTime start;
  final DateTime stop;
  final String title;
  final String? description;
}

/// XMLTV timestamps: `20261108183000 +0800`.
DateTime? parseXmltvTime(String s) {
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?\s*([+-]\d{4})?$').firstMatch(s.trim());
  if (m == null) return null;
  final utc = DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), int.parse(m[4]!), int.parse(m[5]!),
      int.parse(m[6] ?? '0'));
  final off = m[7];
  if (off == null) return utc;
  final sign = off.startsWith('-') ? -1 : 1;
  final minutes = int.parse(off.substring(1, 3)) * 60 + int.parse(off.substring(3, 5));
  return utc.subtract(Duration(minutes: sign * minutes));
}

XmlDocument _xmltvDocument(List<int> bytes) {
  final data = (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) ? gzip.decode(bytes) : bytes;
  return XmlDocument.parse(utf8.decode(data, allowMalformed: true));
}

List<EpgEntry> _programmes(XmlDocument doc) {
  final out = <EpgEntry>[];
  for (final p in doc.findAllElements('programme')) {
    final start = parseXmltvTime(p.getAttribute('start') ?? '');
    final stop = parseXmltvTime(p.getAttribute('stop') ?? '');
    final channel = p.getAttribute('channel');
    final title = p.getElement('title')?.innerText;
    if (start == null || stop == null || channel == null || title == null) continue;
    out.add(EpgEntry(channelId: channel, start: start, stop: stop, title: title, description: p.getElement('desc')?.innerText));
  }
  return out;
}

/// Accepts plain XMLTV bytes or gzip (`.xml.gz` is the documented example in the UI strings).
List<EpgEntry> parseXmltv(List<int> bytes) => _programmes(_xmltvDocument(bytes));

/// A parsed XMLTV file: programmes per channel id plus the channels' display names (used for fallback matching).
class XmltvGuide {
  const XmltvGuide(this.byChannel, this.displayNames);
  final Map<String, List<EpgEntry>> byChannel;
  final Map<String, String> displayNames;

  List<EpgEntry> forChannel(LiveChannel ch) => epgFor(ch, byChannel, displayNames);
}

XmltvGuide parseXmltvGuide(List<int> bytes) {
  final doc = _xmltvDocument(bytes);
  final byChannel = <String, List<EpgEntry>>{};
  for (final e in _programmes(doc)) {
    byChannel.putIfAbsent(e.channelId, () => []).add(e);
  }
  for (final list in byChannel.values) {
    list.sort((a, b) => a.start.compareTo(b.start));
  }
  final names = <String, String>{};
  for (final c in doc.findAllElements('channel')) {
    final id = c.getAttribute('id');
    final name = c.getElement('display-name')?.innerText;
    if (id != null && name != null) names[id] = name;
  }
  return XmltvGuide(byChannel, names);
}

/// The programme on air at [now], if the guide has one.
EpgEntry? currentProgramme(List<EpgEntry> entries, DateTime now) {
  for (final e in entries) {
    if (!now.isBefore(e.start) && now.isBefore(e.stop)) return e;
  }
  return null;
}

/// EPG lookup (changelog 1.1.8: "match by several keywords with fallback"): tvg-id, then tvg-name, then name.
List<EpgEntry> epgFor(LiveChannel ch, Map<String, List<EpgEntry>> byChannel, Map<String, String> displayNames) {
  final candidates = [ch.tvgId, ch.tvgName, ch.name].whereType<String>().map((s) => s.trim()).where((s) => s.isNotEmpty);
  for (final c in candidates) {
    final hit = byChannel[c];
    if (hit != null) return hit;
    final id = displayNames.entries.firstWhere((e) => e.value.toLowerCase() == c.toLowerCase(), orElse: () => const MapEntry('', '')).key;
    if (id.isNotEmpty && byChannel[id] != null) return byChannel[id]!;
  }
  return const [];
}
