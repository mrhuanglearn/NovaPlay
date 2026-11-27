import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/catpaw/spider_api.dart';
import 'package:uzv_reimpl/features/library/watch_repository.dart';
import 'package:uzv_reimpl/features/media_server/media_source.dart';
import 'package:uzv_reimpl/features/player/native_player_api.g.dart';
import 'package:uzv_reimpl/features/player/playback_source.dart';
import 'package:uzv_reimpl/features/player/player_launcher.dart';
import 'package:uzv_reimpl/features/player/session_router.dart';
import 'package:uzv_reimpl/features/player/video_format_probe.dart';
import 'package:uzv_reimpl/features/sniffer/sniffer_service.dart';
import 'package:uzv_reimpl/models/vod.dart';
import 'package:uzv_reimpl/services/media_server_client.dart';
import 'package:dio/dio.dart';

// Real H.264 Baseline/High SPS NAL units (verified byte-accurate ITU-T H.264 RBSP).
// 1. 1280x720 progressive (profile_idc=66 Baseline):
//    67 42 C0 1F DA 01 40 16 EC 04 40 00 00 03 00 40 00 00 0F 03 C6 0C 65 80
// 2. 720x1280 vertical progressive (profile_idc=66, pic_width_mbs_minus1=44 -> 720, pic_height_map_units_minus1=79 -> 1280):
Uint8List _buildH264BaselineSps({
  required int mbsW,
  required int mbsH,
  int cropRight = 0,
  int cropBottom = 0,
}) {
  final bw = _BitWriter()
    ..writeBits(0x67, 8) // nal_ref_idc=3, nal_unit_type=7 (SPS)
    ..writeBits(66, 8) // Baseline profile
    ..writeBits(0xC0, 8)
    ..writeBits(31, 8) // level 3.1
    ..writeUe(0) // sps_id
    ..writeUe(0) // log2_max_frame_num_minus4
    ..writeUe(0) // pic_order_cnt_type = 0
    ..writeUe(0) // log2_max_pic_order_cnt_lsb_minus4
    ..writeUe(1) // max_num_ref_frames
    ..writeBit(0) // gaps_in_frame_num_value_allowed_flag
    ..writeUe(mbsW - 1)
    ..writeUe(mbsH - 1)
    ..writeBit(1) // frame_mbs_only_flag = 1
    ..writeBit(1); // direct_8x8_inference_flag
  if (cropRight > 0 || cropBottom > 0) {
    bw
      ..writeBit(1)
      ..writeUe(0)
      ..writeUe(cropRight)
      ..writeUe(0)
      ..writeUe(cropBottom);
  } else {
    bw.writeBit(0);
  }
  bw
    ..writeBit(0) // vui_parameters_present_flag
    ..writeBit(1); // rbsp_stop_one_bit
  return bw.toRbspNal();
}

Uint8List _buildHevcSps({required int width, required int height, int confBottom = 0}) {
  final bw = _BitWriter()
    ..writeBits(0x42, 8) // nal_unit_type = 33 ((0x42 >> 1) & 0x3F == 33)
    ..writeBits(0x01, 8)
    ..writeBits(0, 4) // vps_id
    ..writeBits(0, 3) // max_sub_layers_minus1 = 0
    ..writeBit(1); // temporal_id_nesting_flag
  for (var i = 0; i < 12; i++) {
    bw.writeBits(0, 8); // 96-bit general profile_tier_level
  }
  bw
    ..writeUe(0) // sps_id
    ..writeUe(1) // chroma_format_idc = 1 (4:2:0)
    ..writeUe(width)
    ..writeUe(height + confBottom * 2);
  if (confBottom > 0) {
    bw
      ..writeBit(1)
      ..writeUe(0)
      ..writeUe(0)
      ..writeUe(0)
      ..writeUe(confBottom);
  } else {
    bw.writeBit(0);
  }
  bw.writeBit(1);
  return bw.toRbspNal(headerBytes: 2);
}

Uint8List _mp4Box(String type, List<int> payload) {
  final total = 8 + payload.length;
  final out = Uint8List(total);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, total);
  for (var i = 0; i < 4; i++) {
    out[4 + i] = type.codeUnitAt(i);
  }
  out.setRange(8, total, payload);
  return out;
}

Uint8List _buildMp4({
  required int width,
  required int height,
  bool rotate90 = false,
  int mdatBeforeMoovSize = 0,
  int leadingAudioTrackBytes = 0,
}) {
  final ftyp = _mp4Box('ftyp', utf8.encode('isom\x00\x00\x02\x00isomiso2'));
  final tkhdBody = Uint8List(84);
  final tbd = ByteData.sublistView(tkhdBody);
  tbd.setUint8(0, 0); // version 0
  tbd.setUint8(3, 3); // flags
  tbd.setUint32(12, 1); // track_ID
  // Matrix at offset 40:
  if (rotate90) {
    tbd.setInt32(40, 0); // a
    tbd.setInt32(44, 0x00010000); // b
    tbd.setInt32(52, -0x00010000); // c
    tbd.setInt32(56, 0); // d
  } else {
    tbd.setInt32(40, 0x00010000);
    tbd.setInt32(56, 0x00010000);
  }
  tbd.setInt32(72, 0x40000000); // w
  tbd.setUint32(76, width << 16);
  tbd.setUint32(80, height << 16);
  final tkhd = _mp4Box('tkhd', tkhdBody);

  final hdlrBody = Uint8List(24);
  hdlrBody.setRange(8, 12, utf8.encode('vide'));
  final hdlr = _mp4Box('hdlr', hdlrBody);

  final avc1Body = Uint8List(78);
  final abd = ByteData.sublistView(avc1Body);
  abd.setUint16(6, 1);
  abd.setUint16(24, width);
  abd.setUint16(26, height);
  final avc1 = _mp4Box('avc1', avc1Body);

  final stsdHeader = Uint8List(8);
  ByteData.sublistView(stsdHeader).setUint32(4, 1);
  final stsd = _mp4Box('stsd', [...stsdHeader, ...avc1]);
  final stbl = _mp4Box('stbl', stsd);
  final minf = _mp4Box('minf', stbl);
  final mdia = _mp4Box('mdia', [...hdlr, ...minf]);
  final videoTrak = _mp4Box('trak', [...tkhd, ...mdia]);

  final moovPayload = <int>[];
  if (leadingAudioTrackBytes > 0) {
    final audioHdlrBody = Uint8List(24);
    audioHdlrBody.setRange(8, 12, utf8.encode('soun'));
    final audioStsz = _mp4Box('stsz', Uint8List(leadingAudioTrackBytes));
    final audioStbl = _mp4Box('stbl', audioStsz);
    final audioMinf = _mp4Box('minf', audioStbl);
    final audioMdia = _mp4Box('mdia', [..._mp4Box('hdlr', audioHdlrBody), ...audioMinf]);
    final audioTkhd = _mp4Box('tkhd', Uint8List(84));
    moovPayload.addAll(_mp4Box('trak', [...audioTkhd, ...audioMdia]));
  }
  moovPayload.addAll(videoTrak);
  final moov = _mp4Box('moov', moovPayload);

  if (mdatBeforeMoovSize > 0) {
    final mdat = _mp4Box('mdat', Uint8List(mdatBeforeMoovSize));
    return Uint8List.fromList([...ftyp, ...mdat, ...moov]);
  }
  return Uint8List.fromList([...ftyp, ...moov, ..._mp4Box('mdat', Uint8List(32))]);
}

Uint8List _buildMpegTsWithSps(Uint8List spsNal, {required int streamType, List<int> prefix = const []}) {
  Uint8List tsPacket(int pid, int cc, List<int> payload, {bool pusi = true}) {
    final pkt = Uint8List(188);
    pkt.fillRange(0, 188, 0xFF);
    pkt[0] = 0x47;
    pkt[1] = (pusi ? 0x40 : 0x00) | ((pid >> 8) & 0x1F);
    pkt[2] = pid & 0xFF;
    final adaptLen = 184 - payload.length - 1;
    if (adaptLen >= 0) {
      pkt[3] = 0x30 | (cc & 0x0F); // adaptation + payload
      pkt[4] = adaptLen;
      if (adaptLen > 0) pkt[5] = 0x00;
      pkt.setRange(188 - payload.length, 188, payload);
    } else {
      pkt[3] = 0x10 | (cc & 0x0F);
      pkt.setRange(4, 188, payload.sublist(0, 184));
    }
    return pkt;
  }

  // PAT: program 1 -> PMT PID 0x0100
  final pat = [
    0x00, // pointer_field
    0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00,
    0x00, 0x01, 0xE1, 0x00, // prog 1 -> 0x0100
    0x00, 0x00, 0x00, 0x00, // CRC placeholder
  ];
  // PMT: video elementary stream -> PID 0x0101
  final pmt = [
    0x00, // pointer_field
    0x02, 0xB0, 0x12, 0x00, 0x01, 0xC1, 0x00, 0x00,
    0xE1, 0x01, 0xF0, 0x00,
    streamType, 0xE1, 0x01, 0xF0, 0x00,
    0x00, 0x00, 0x00, 0x00,
  ];
  // PES packet with Annex-B start code + SPS NAL
  final pes = [
    0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x01,
    ...spsNal,
  ];
  return Uint8List.fromList([
    ...prefix,
    ...tsPacket(0x0000, 0, pat),
    ...tsPacket(0x0100, 0, pmt),
    ...tsPacket(0x0101, 0, pes),
  ]);
}

Uint8List _buildMkv({
  required int pixelW,
  required int pixelH,
  int? displayW,
  int? displayH,
  int? displayUnit,
}) {
  List<int> uintBytes(int v) => [(v >> 8) & 0xFF, v & 0xFF];
  List<int> el(List<int> id, List<int> body) => [...id, 0x80 | body.length, ...body];

  final ebmlHeader = el([0x1A, 0x45, 0xDF, 0xA3], [0x42, 0x86, 0x81, 0x01]);
  final audioEntry = el([0xAE], [
    ...el([0xD7], [0x01]),
    ...el([0x83], [0x02]), // TrackType = 2 (audio)
  ]);
  final videoChildren = <int>[
    ...el([0xB0], uintBytes(pixelW)),
    ...el([0xBA], uintBytes(pixelH)),
    if (displayW != null) ...el([0x54, 0xB0], uintBytes(displayW)),
    if (displayH != null) ...el([0x54, 0xBA], uintBytes(displayH)),
    if (displayUnit != null) ...el([0x54, 0xB2], [displayUnit]),
  ];
  final videoEntry = el([0xAE], [
    ...el([0xD7], [0x02]),
    ...el([0x83], [0x01]), // TrackType = 1 (video)
    ...el([0xE0], videoChildren),
  ]);
  final tracksBody = [...audioEntry, ...videoEntry];
  final tracks = [0x16, 0x54, 0xAE, 0x6B, 0x80 | tracksBody.length, ...tracksBody];
  // Segment with EBML unknown-size 8-byte VINT (0x01FFFFFFFFFFFFFF)
  final segment = [
    0x18, 0x53, 0x80, 0x67,
    0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    ...tracks,
  ];
  return Uint8List.fromList([...ebmlHeader, ...segment]);
}

Uint8List _buildFlvOnMetaData(double width, double height) {
  List<int> amfProp(String name, double val) {
    final numBytes = Uint8List(8);
    ByteData.sublistView(numBytes).setFloat64(0, val);
    return [(name.length >> 8) & 0xFF, name.length & 0xFF, ...name.codeUnits, 0x00, ...numBytes];
  }

  final scriptBody = <int>[
    0x02, 0x00, 0x0A, ...'onMetaData'.codeUnits,
    0x08, 0x00, 0x00, 0x00, 0x02,
    ...amfProp('width', width),
    ...amfProp('height', height),
    0x00, 0x00, 0x09,
  ];
  final len = scriptBody.length;
  return Uint8List.fromList([
    0x46, 0x4C, 0x56, 0x01, 0x05, 0x00, 0x00, 0x00, 0x09, // FLV header
    0x00, 0x00, 0x00, 0x00, // PreviousTagSize0
    18, (len >> 16) & 0xFF, (len >> 8) & 0xFF, len & 0xFF, 0, 0, 0, 0, 0, 0, 0,
    ...scriptBody,
  ]);
}

class _RecordingHost extends NativePlayerHostApi {
  _RecordingHost({this.router});

  final PlayerSessionRouter? router;
  final opened = <OpenPlayerRequest>[];
  final sources = <SourcePayload>[];
  final videoSizes = <(String, int, int, int, int)>[];

  @override
  Future<void> openPlayerPage(OpenPlayerRequest request) async {
    final src = request.initialSource;
    final r = router;
    final budgetMs = (request.probeBudgetMs ?? 0).clamp(0, 260);
    if (r != null &&
        budgetMs > 0 &&
        effectiveOrientationMode(request.playbackConfig) == 'auto' &&
        request.epgProgrammes == null &&
        src != null &&
        src.success &&
        (src.url ?? '').isNotEmpty &&
        (src.videoWidth == null || src.videoHeight == null)) {
      final probed = await r.onProbeVideoSize(
        request.sessionId,
        request.startLineIndex,
        request.startEpisodeIndex,
        src.url!,
        src.headers ?? const {},
        budgetMs,
      );
      if (probed != null) {
        if (probed.width < 0) return; // cancelled before open
        src.videoWidth = probed.width;
        src.videoHeight = probed.height;
      }
    }
    opened.add(request);
  }

  @override
  Future<void> provideSource(SourcePayload payload) async => sources.add(payload);

  @override
  Future<void> updateVideoSize(String sessionId, int lineIndex, int episodeIndex, int width, int height) async {
    videoSizes.add((sessionId, lineIndex, episodeIndex, width, height));
  }
}

class _DelayedPlayApi extends SpiderApi {
  _DelayedPlayApi(this._fn) : super(0);
  final Future<PlayResult> Function() _fn;

  @override
  Future<PlayResult> play(SpiderSite site, String flag, String id) => _fn();
}

class _FakeDioAdapter implements HttpClientAdapter {
  _FakeDioAdapter(this.payload);
  final Map<String, Object?> payload;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      ResponseBody.fromString(jsonEncode(payload), 200, headers: {
        Headers.contentTypeHeader: ['application/json'],
      });

  @override
  void close({bool force = false}) {}
}

void main() {
  group('VideoFormatProbe parsers', () {
    test('parses HLS master playlist RESOLUTION and picks the highest variant', () {
      const m3u8 = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=540x960
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION="1080x1920",CODECS="avc1.640028"
high.m3u8
''';
      expect(VideoFormatProbe.parseHlsMasterResolution(m3u8), (width: 1080, height: 1920));
    });

    test('parses DASH MPD Representation width and height', () {
      const mpd = '''<?xml version="1.0"?>
<MPD>
  <Period><AdaptationSet>
    <Representation id="sd" width="360" height="640"/>
    <Representation id="hd" height="1920" width="1080"/>
  </AdaptationSet></Period>
</MPD>''';
      expect(VideoFormatProbe.parseDashMpd(mpd), (width: 1080, height: 1920));
    });

    test('parses H.264 SPS progressive, vertical, and frame-cropped 1080p dimensions', () {
      final vertical = _buildH264BaselineSps(mbsW: 45, mbsH: 80);
      expect(VideoFormatProbe.parseH264SpsNal(vertical), (width: 720, height: 1280));

      // 1920x1088 coded -> cropBottom=4 (cropUnitY=2 for 4:2:0) -> 1920x1080
      final cropped1080p = _buildH264BaselineSps(mbsW: 120, mbsH: 68, cropBottom: 4);
      expect(VideoFormatProbe.parseH264SpsNal(cropped1080p), (width: 1920, height: 1080));
    });

    test('parses HEVC SPS vertical and conformance-cropped dimensions', () {
      final verticalHevc = _buildHevcSps(width: 1080, height: 1920, confBottom: 4);
      expect(VideoFormatProbe.parseHevcSpsNal(verticalHevc), (width: 1080, height: 1920));
    });

    test('parses MP4 faststart and swaps 90-degree tkhd rotation matrix into portrait', () {
      final portraitMp4 = _buildMp4(width: 1080, height: 1920);
      expect(VideoFormatProbe.parseContainerBytes(portraitMp4).dimensions, (width: 1080, height: 1920));

      final rotatedPhoneMp4 = _buildMp4(width: 1920, height: 1080, rotate90: true);
      expect(VideoFormatProbe.parseContainerBytes(rotatedPhoneMp4).dimensions, (width: 1080, height: 1920));
    });

    test('parses MKV EBML tracks with unknown segment size, DisplayWidth pixels, and DisplayUnit=3 DAR', () {
      final verticalMkv = _buildMkv(pixelW: 1080, pixelH: 1920);
      expect(VideoFormatProbe.parseContainerBytes(verticalMkv).dimensions, (width: 1080, height: 1920));

      final anamorphicMkv = _buildMkv(pixelW: 1440, pixelH: 1080, displayW: 1920, displayH: 1080);
      expect(VideoFormatProbe.parseContainerBytes(anamorphicMkv).dimensions, (width: 1920, height: 1080));

      final darPortraitMkv = _buildMkv(pixelW: 1080, pixelH: 1920, displayW: 9, displayH: 16, displayUnit: 3);
      expect(VideoFormatProbe.parseContainerBytes(darPortraitMkv).dimensions, (width: 1080, height: 1920));
    });

    test('parses FLV onMetaData width and height', () {
      final flv = _buildFlvOnMetaData(720, 1280);
      expect(VideoFormatProbe.parseContainerBytes(flv).dimensions, (width: 720, height: 1280));
    });

    test('parses MPEG-TS segments even when disguised with a fake PNG header', () {
      const fakePngPrefix = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D];
      final hevcSps = _buildHevcSps(width: 1080, height: 1920);
      final disguisedTs = _buildMpegTsWithSps(hevcSps, streamType: 0x24, prefix: fakePngPrefix);
      expect(VideoFormatProbe.parseContainerBytes(disguisedTs).dimensions, (width: 1080, height: 1920));
    });

    test('rejects empty, truncated, tiny, or garbage inputs safely without throwing', () {
      expect(VideoFormatProbe.parseContainerBytes(Uint8List(0)).dimensions, isNull);
      expect(VideoFormatProbe.parseContainerBytes(Uint8List.fromList([1, 2, 3, 4])).dimensions, isNull);
      expect(VideoFormatProbe.parseH264SpsNal(Uint8List.fromList([0x67, 0x42])), isNull);
      expect(VideoFormatProbe.parseHevcSpsNal(Uint8List.fromList([0x42, 0x01, 0x00])), isNull);
      expect(VideoFormatProbe.parseContainerBytes(_buildFlvOnMetaData(2, 2)).dimensions, isNull);
      expect(VideoFormatProbe.shouldSkipProbe('http://127.0.0.1:2333/uzv-iso/tok/main.m2ts'), isTrue);
      expect(VideoFormatProbe.shouldSkipProbe('rtmp://live.example.com/app/stream'), isTrue);
    });
  });

  group('VideoFormatProbe network & file probing', () {
    late HttpServer server;
    late Directory tempDir;
    late int rangeRequests;
    late int bytesServed;
    late int encryptedSegRequests;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('uzv_probe_test');
      rangeRequests = 0;
      bytesServed = 0;
      encryptedSegRequests = 0;
      final tailMoovMp4 = _buildMp4(width: 1080, height: 1920, mdatBeforeMoovSize: 150000);
      final disguisedTs = _buildMpegTsWithSps(
        _buildH264BaselineSps(mbsW: 45, mbsH: 80),
        streamType: 0x1B,
        prefix: const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
      );
      final fmp4Init = _buildMp4(width: 1080, height: 1920);

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final path = req.uri.path;
        if (path == '/master.m3u8') {
          req.response
            ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
            ..write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1500000\nvariant.m3u8\n');
          await req.response.close();
          return;
        }
        if (path == '/variant.m3u8') {
          req.response
            ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
            ..write('#EXTM3U\n#EXTINF:4.0,\nseg0.jpg\n');
          await req.response.close();
          return;
        }
        if (path == '/seg0.jpg') {
          req.response.add(disguisedTs);
          await req.response.close();
          return;
        }
        if (path == '/fmp4.m3u8') {
          req.response
            ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
            ..write('#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:4.0,\nchunk0.m4s\n');
          await req.response.close();
          return;
        }
        if (path == '/init.mp4') {
          req.response.add(fmp4Init);
          await req.response.close();
          return;
        }
        if (path == '/tail_moov.mp4') {
          rangeRequests++;
          final range = req.headers.value(HttpHeaders.rangeHeader) ?? '';
          final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range);
          if (m != null) {
            final s = int.parse(m.group(1)!);
            final e = int.parse(m.group(2)!).clamp(0, tailMoovMp4.length - 1);
            final slice = Uint8List.sublistView(tailMoovMp4, s, e + 1);
            bytesServed += slice.length;
            req.response
              ..statusCode = HttpStatus.partialContent
              ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $s-$e/${tailMoovMp4.length}')
              ..contentLength = slice.length
              ..add(slice);
            await req.response.close();
            return;
          }
        }
        if (path == '/no_range_huge.mp4') {
          // Server ignores Range and streams 1 MB with 200 OK; client must stop after ~64 KB.
          final fastMp4 = _buildMp4(width: 720, height: 1280);
          req.response.statusCode = HttpStatus.ok;
          req.response.add(fastMp4);
          for (var i = 0; i < 16; i++) {
            req.response.add(Uint8List(65536));
          }
          await req.response.close().catchError((Object _) {});
          return;
        }
        if (path == '/referer_guarded.m3u8') {
          final ref = req.headers.value('referer') ?? '';
          final ua = req.headers.value(HttpHeaders.userAgentHeader) ?? '';
          if (ref != 'https://allowed.example/watch?a=1&b=2' || ua != 'CustomPlayer/2.0') {
            req.response.statusCode = HttpStatus.forbidden;
            await req.response.close();
            return;
          }
          req.response
            ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
            ..write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1080x1920\nhigh.m3u8\n');
          await req.response.close();
          return;
        }
        if (path == '/encrypted.m3u8') {
          req.response
            ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
            ..write('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.key"\n#EXTINF:4.0,\nenc0.ts\n');
          await req.response.close();
          return;
        }
        if (path == '/enc0.ts') {
          encryptedSegRequests++;
          req.response.add(Uint8List(4096));
          await req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      tempDir.deleteSync(recursive: true);
    });

    VideoFormatProbe realProbe({Duration sliceTimeout = const Duration(milliseconds: 2500)}) {
      final p = VideoFormatProbe(httpClientFactory: HttpClient.new, sliceTimeout: sliceTimeout);
      addTearDown(p.close);
      return p;
    }

    test('follows HLS master -> variant -> disguised .jpg TS segment and extracts 720x1280', () async {
      final probe = realProbe();
      final dims = await probe.probe('http://127.0.0.1:${server.port}/master.m3u8');
      expect(dims, (width: 720, height: 1280));
    });

    test('follows HLS #EXT-X-MAP init.mp4 segment and extracts 1080x1920', () async {
      final probe = realProbe();
      final dims = await probe.probe('http://127.0.0.1:${server.port}/fmp4.m3u8');
      expect(dims, (width: 1080, height: 1920));
    });

    test('resolves tail-moov MP4 via two small HTTP Range slices without downloading mdat', () async {
      final probe = realProbe();
      final dims = await probe.probe('http://127.0.0.1:${server.port}/tail_moov.mp4');
      expect(dims, (width: 1080, height: 1920));
      expect(rangeRequests, 2);
      expect(bytesServed, lessThan(70000));
    });

    test('resolves local tail-moov MP4 file via RandomAccessFile seek', () async {
      final file = File('${tempDir.path}/local_tail.mp4');
      await file.writeAsBytes(_buildMp4(width: 1080, height: 1920, mdatBeforeMoovSize: 150000));
      final probe = realProbe();
      expect(await probe.probe(file.uri.toString()), (width: 1080, height: 1920));
    });

    test('stops reading at 64 KB even when server ignores Range and streams 200 OK', () async {
      final probe = realProbe();
      final dims = await probe.probe('http://127.0.0.1:${server.port}/no_range_huge.mp4');
      expect(dims, (width: 720, height: 1280));
    });

    test('normalizes TVBox inline pipe headers (url|Referer=...&UA=...) before probing', () async {
      expect(
        VideoFormatProbe.isDirectWarmupCandidate(
          'https://cdn.example.com/v.m3u8|Referer=https://allowed.example/watch?a=1&b=2&UA=CustomPlayer/2.0',
        ),
        isTrue,
      );
      final probe = realProbe();
      final rawUrl =
          'http://127.0.0.1:${server.port}/referer_guarded.m3u8|Referer=https://allowed.example/watch?a=1&b=2&UA=CustomPlayer/2.0';
      final dims = await probe.probe(rawUrl);
      expect(dims, (width: 1080, height: 1920));
      // Lookup by stripped URL also hits the same cache entry.
      expect(probe.cached('http://127.0.0.1:${server.port}/referer_guarded.m3u8'), (width: 1080, height: 1920));
    });

    test('resolves downloaded local HLS media playlist (.m3u8 -> local .ts segment) on disk', () async {
      final tsBytes = _buildMpegTsWithSps(_buildH264BaselineSps(mbsW: 45, mbsH: 80), streamType: 0x1B);
      final tsFile = File('${tempDir.path}/seg_0.ts');
      await tsFile.writeAsBytes(tsBytes);
      final m3u8File = File('${tempDir.path}/index.m3u8');
      await m3u8File.writeAsString('#EXTM3U\n#EXTINF:4.0,\nseg_0.ts\n');

      final probe = realProbe();
      expect(await probe.probe(m3u8File.uri.toString()), (width: 720, height: 1280));
    });

    test('skips fetching AES-128 encrypted TS segments when master/media playlist has no RESOLUTION', () async {
      final probe = realProbe();
      addTearDown(probe.close);
      final dims = await probe.probe('http://127.0.0.1:${server.port}/encrypted.m3u8');
      expect(dims, isNull);
      expect(encryptedSegRequests, 0, reason: 'must not waste bandwidth downloading encrypted TS ciphertext');
    });

    test('reuses pooled keep-alive connection across multi-step HLS chain and closes cleanly', () async {
      final clientPorts = <int>{};
      final tsSeg = _buildMpegTsWithSps(_buildH264BaselineSps(mbsW: 45, mbsH: 80), streamType: 0x1B);
      final poolServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => poolServer.close(force: true));
      poolServer.listen((req) async {
        final port = req.connectionInfo?.remotePort;
        if (port != null) clientPorts.add(port);
        if (req.uri.path == '/master.m3u8') {
          final body = utf8.encode('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=900000\nsub.m3u8\n');
          req.response
            ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
            ..contentLength = body.length
            ..add(body);
          await req.response.close();
          return;
        }
        if (req.uri.path == '/sub.m3u8') {
          final body = utf8.encode('#EXTM3U\n#EXTINF:4.0,\nseg0.ts\n');
          req.response
            ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
            ..contentLength = body.length
            ..add(body);
          await req.response.close();
          return;
        }
        if (req.uri.path == '/seg0.ts') {
          req.response
            ..contentLength = tsSeg.length
            ..add(tsSeg);
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });

      final probe = realProbe();
      addTearDown(probe.close);
      final dims = await probe.probe('http://127.0.0.1:${poolServer.port}/master.m3u8');
      expect(dims, (width: 720, height: 1280));
      expect(clientPorts, hasLength(1), reason: 'master -> variant -> seg0 must reuse one pooled TCP socket');
      probe.close();
    });

    test('omits Range header on .m3u8 / .mpd manifests and aborts huge VOD media playlists early', () async {
      var hugeM3u8TailSent = false;
      final tsSeg = _buildMpegTsWithSps(_buildH264BaselineSps(mbsW: 45, mbsH: 80), streamType: 0x1B);
      final manifestServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => manifestServer.close(force: true));
      manifestServer.listen((req) async {
        // Reject any manifest request carrying a Range header (simulates strict signed CDN URLs).
        if ((req.uri.path.endsWith('.m3u8') || req.uri.path.endsWith('.mpd')) &&
            req.headers.value(HttpHeaders.rangeHeader) != null) {
          req.response.statusCode = HttpStatus.forbidden;
          await req.response.close();
          return;
        }
        if (req.uri.path == '/signed.mpd') {
          req.response
            ..headers.contentType = ContentType('application', 'dash+xml')
            ..write('<?xml version="1.0"?><MPD><Representation width="1080" height="1920"/></MPD>');
          await req.response.close();
          return;
        }
        if (req.uri.path == '/huge_vod.m3u8') {
          req.response
            ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
            ..bufferOutput = false;
          final headBuf = StringBuffer('#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\nseg0.ts\n');
          for (var i = 1; i < 450; i++) {
            headBuf.write('#EXTINF:4.0,\nsegment_number_${i}_padding_line.ts\n');
          }
          req.response.write(headBuf.toString());
          await req.response.flush().catchError((Object _) {});
          await Future<void>.delayed(const Duration(milliseconds: 350));
          hugeM3u8TailSent = true;
          req.response.write('#EXT-X-ENDLIST\n');
          await req.response.close().catchError((Object _) {});
          return;
        }
        if (req.uri.path == '/seg0.ts') {
          req.response.add(tsSeg);
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });

      final probe = realProbe();
      addTearDown(probe.close);
      expect(await probe.probe('http://127.0.0.1:${manifestServer.port}/signed.mpd'), (width: 1080, height: 1920));

      final sw = Stopwatch()..start();
      expect(await probe.probe('http://127.0.0.1:${manifestServer.port}/huge_vod.m3u8'), (width: 720, height: 1280));
      expect(sw.elapsedMilliseconds, lessThan(250), reason: 'must stop reading huge media m3u8 once first segment seen');
      expect(hugeM3u8TailSent, isFalse);
    });

    test('aborts binary stream download as soon as header chunk yields dimensions instead of waiting for 64 KB', () async {
      final fastMp4Head = _buildMp4(width: 1920, height: 1080, rotate90: true);
      final slowTailServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => slowTailServer.close(force: true));
      slowTailServer.listen((req) async {
        req.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-65535/1048576')
          ..bufferOutput = false;
        // Send the ~400-byte MP4 header + padding (~1.5 KB) immediately, then stall before the rest of 64 KB.
        req.response.add([...fastMp4Head, ...Uint8List(1024)]);
        await req.response.flush().catchError((Object _) {});
        await Future<void>.delayed(const Duration(milliseconds: 500));
        req.response.add(Uint8List(63000));
        await req.response.close().catchError((Object _) {});
      });

      final probe = realProbe();
      addTearDown(probe.close);
      final sw = Stopwatch()..start();
      final dims = await probe.probe('http://127.0.0.1:${slowTailServer.port}/stream.mp4');
      expect(dims, (width: 1080, height: 1920));
      expect(sw.elapsedMilliseconds, lessThan(200), reason: 'must return immediately after first header chunk');
    });

    test('resolves oversized head moov (> 64 KB) when a long audio track precedes the video track', () async {
      final audioFirstMp4 = _buildMp4(
        width: 1920,
        height: 1080,
        rotate90: true,
        leadingAudioTrackBytes: 85000,
      );
      // 1. Local file RandomAccessFile seek across oversized audio track inside head moov:
      final localFile = File('${tempDir.path}/audio_first_large_moov.mp4');
      await localFile.writeAsBytes(audioFirstMp4);
      final probe = realProbe();
      addTearDown(probe.close);
      expect(await probe.probe(localFile.uri.toString()), (width: 1080, height: 1920));

      // 2. HTTP Range jump directly from head slice to video trak offset inside moov:
      var sliceRequests = 0;
      final moovServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => moovServer.close(force: true));
      moovServer.listen((req) async {
        sliceRequests++;
        final range = req.headers.value(HttpHeaders.rangeHeader) ?? '';
        final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
        final s = int.parse(m.group(1)!);
        final e = int.parse(m.group(2)!).clamp(0, audioFirstMp4.length - 1);
        final slice = Uint8List.sublistView(audioFirstMp4, s, e + 1);
        req.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $s-$e/${audioFirstMp4.length}')
          ..contentLength = slice.length
          ..add(slice);
        await req.response.close();
      });

      expect(await probe.probe('http://127.0.0.1:${moovServer.port}/audio_first.mp4'), (width: 1080, height: 1920));
      expect(sliceRequests, 2, reason: 'skips 85 KB audio sample table to land directly on video trak');
    });

    test('isolates in-flight probes by anti-hotlink headers and cleans up stalled HTTP sockets via sliceTimeout',
        () async {
      final slowAuthServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => slowAuthServer.close(force: true));
      slowAuthServer.listen((req) async {
        if (req.uri.path == '/guarded.m3u8') {
          if (req.headers.value('referer') != 'https://ok.example/') {
            await Future<void>.delayed(const Duration(milliseconds: 60));
            req.response.statusCode = HttpStatus.forbidden;
            await req.response.close();
            return;
          }
          req.response
            ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
            ..write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1080x1920\nv.m3u8\n');
          await req.response.close();
          return;
        }
        if (req.uri.path == '/stalled.mp4') {
          req.response
            ..statusCode = HttpStatus.partialContent
            ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-65535/1048576')
            ..bufferOutput = false;
          req.response.add(const [0, 0, 0, 20]);
          await req.response.flush().catchError((Object _) {});
          // Never close response; sliceTimeout must abort cleanly.
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });

      final probe = realProbe(sliceTimeout: const Duration(milliseconds: 120));
      final url = 'http://127.0.0.1:${slowAuthServer.port}/guarded.m3u8';
      final unauthFut = probe.probe(url);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final authFut = probe.probe(url, headers: const {'Referer': 'https://ok.example/'});
      expect(await authFut, (width: 1080, height: 1920));
      expect(await unauthFut, isNull);

      final stalledUrl = 'http://127.0.0.1:${slowAuthServer.port}/stalled.mp4';
      final sw = Stopwatch()..start();
      expect(await probe.probe(stalledUrl, timeout: const Duration(milliseconds: 500)), isNull);
      expect(sw.elapsedMilliseconds, lessThan(350), reason: 'sliceTimeout aborts stalled body without hanging');
    });
  });

  group('PlayerLauncher & PlayerSession adaptive launch interaction', () {
    late Directory dir;
    late HistoryRepository history;
    late HttpServer mediaServer;

    const site = SpiderSite(key: 'shortdrama', name: '短剧', api: '/spider/shortdrama/3');
    VodDetail makeDetail(String id) => VodDetail(
          item: VodItem(id: id, name: '剧集_$id', siteKey: site.key),
          lines: parsePlayLines('线路一', r'第1集$v1#第2集$v2'),
        );

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('uzv_adaptive_launch');
      history = HistoryRepository(store: JsonStore('history.json', baseDir: dir));
      mediaServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      mediaServer.listen((req) async {
        if (req.uri.path == '/vertical.m3u8') {
          req.response.write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=1080x1920\nhigh.m3u8\n');
          await req.response.close();
          return;
        }
        if (req.uri.path == '/slow_vertical.m3u8') {
          await Future<void>.delayed(const Duration(milliseconds: 180));
          req.response.write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=720x1280\nhigh.m3u8\n');
          await req.response.close();
          return;
        }
        if (req.uri.path == '/encrypted_only.m3u8') {
          req.response.write('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="k.key"\n#EXTINF:4.0,\nenc.ts\n');
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });
    });

    tearDown(() async {
      await mediaServer.close(force: true);
      dir.deleteSync(recursive: true);
    });

    PlayerLauncher buildLauncher(_RecordingHost host, PlayerSessionRouter router,
        {Duration budget = const Duration(milliseconds: 300)}) {
      final probe = VideoFormatProbe(httpClientFactory: HttpClient.new);
      addTearDown(probe.close);
      return PlayerLauncher(
        configs: PlayerConfigRepository(store: JsonStore('player_config.json', baseDir: dir)),
        sniffer: SnifferService(),
        host: host,
        router: router,
        formatProbe: probe,
        fastLaunchBudget: budget,
        installRouter: false,
        enableWakelock: () async {},
        disableWakelock: () async {},
      );
    }

    test('fast stream resolves format before open so player opens immediately in portrait', () async {
      final router = PlayerSessionRouter();
      final host = _RecordingHost(router: router);
      final launcher = buildLauncher(host, router);
      final api = _DelayedPlayApi(() async => PlayResult(url: 'http://127.0.0.1:${mediaServer.port}/vertical.m3u8'));

      final playFuture = launcher.play(site: site, api: api, detail: makeDetail('fast_ep'), history: history);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(host.opened, hasLength(1));
      final opened = host.opened.single;
      expect(opened.initialSource?.videoWidth, 1080);
      expect(opened.initialSource?.videoHeight, 1920);

      await router.onPageClosed(PageClosedEvent(sessionId: opened.sessionId, positionSeconds: 5, completed: false));
      await playFuture;
    });

    test('slow spider opens player promptly in default landscape, then pushes portrait size once resolved', () async {
      final router = PlayerSessionRouter();
      final host = _RecordingHost(router: router);
      final launcher = buildLauncher(host, router, budget: const Duration(milliseconds: 60));
      var playCalls = 0;
      final api = _DelayedPlayApi(() async {
        playCalls++;
        await Future<void>.delayed(const Duration(milliseconds: 180));
        return PlayResult(url: 'http://127.0.0.1:${mediaServer.port}/vertical.m3u8');
      });

      final sw = Stopwatch()..start();
      final playFuture = launcher.play(site: site, api: api, detail: makeDetail('slow_spider_ep'), history: history);
      while (host.opened.isEmpty && sw.elapsedMilliseconds < 500) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      // Player opened promptly without waiting for the 180ms spider!
      expect(host.opened, hasLength(1));
      expect(sw.elapsedMilliseconds, lessThan(150));
      final opened = host.opened.single;
      expect(opened.initialSource, isNull, reason: 'opens in default landscape first while spider is still resolving');
      expect(opened.initialVideoWidth, isNull);

      // Native asks for the episode; single in-flight spider.play is reused and portrait size is pushed.
      await router.onEpisodeRequest(
        EpisodeRequest(sessionId: opened.sessionId, requestId: 1, lineIndex: 0, episodeIndex: 0, qualityIndex: 0),
      );
      expect(playCalls, 1, reason: 'must not call spider.play twice');
      expect(host.sources, hasLength(1));

      await Future<void>.delayed(const Duration(milliseconds: 120));
      final gotSize = (host.sources.single.videoWidth == 1080 && host.sources.single.videoHeight == 1920) ||
          host.videoSizes.contains((opened.sessionId, 0, 0, 1080, 1920));
      expect(gotSize, isTrue, reason: 'portrait dimensions must reach the open player');

      await router.onPageClosed(PageClosedEvent(sessionId: opened.sessionId, positionSeconds: 3, completed: false));
      await playFuture;
    });

    test('fast URL with slow header probe opens within unified budget and pushes late portrait size', () async {
      final router = PlayerSessionRouter();
      final host = _RecordingHost(router: router);
      final launcher = buildLauncher(host, router, budget: const Duration(milliseconds: 60));
      final api = _DelayedPlayApi(() async => PlayResult(url: 'http://127.0.0.1:${mediaServer.port}/slow_vertical.m3u8'));

      final sw = Stopwatch()..start();
      final playFuture = launcher.play(site: site, api: api, detail: makeDetail('slow_probe_ep'), history: history);
      while (host.opened.isEmpty && sw.elapsedMilliseconds < 400) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(host.opened, hasLength(1));
      expect(sw.elapsedMilliseconds, lessThan(140), reason: 'no double budget stall');
      final opened = host.opened.single;
      expect(opened.initialSource?.url, 'http://127.0.0.1:${mediaServer.port}/slow_vertical.m3u8');
      expect(opened.initialSource?.videoWidth, isNull);

      // Once the 180ms probe finishes, updateVideoSize adapts the open player to portrait!
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(host.videoSizes, [(opened.sessionId, 0, 0, 720, 1280)]);

      await router.onPageClosed(PageClosedEvent(sessionId: opened.sessionId, positionSeconds: 2, completed: false));
      await playFuture;
    });

    test('VodEpisodePrewarmCache pre-resolves read-only spiders for 0ms click while skipping cloud drives', () async {
      expect(
        VodEpisodePrewarmCache.canWarmupSpiderEpisode(site: site, lineName: '高清m3u8', episodeUrl: 'ep_1001'),
        isTrue,
      );
      expect(
        VodEpisodePrewarmCache.canWarmupSpiderEpisode(
          site: const SpiderSite(key: 'nodejs_juxiafan', name: '「直」剧下饭', api: '/spider/juxiafan/3'),
          lineName: '专线1',
          episodeUrl: 'ep_2002',
        ),
        isTrue,
        reason: 'explicit 「直」/「采」 direct sites must not be falsely blocked by nickname substrings',
      );
      for (final (panSite, lineName, epUrl) in const [
        (SpiderSite(key: 'nodejs_wogg', name: '玩偶哥哥', api: '/spider/wogg/3'), '夸克原画', 'share_1'),
        (SpiderSite(key: 'nodejs_pomo', name: '「盘」Pomo', api: '/spider/pomo/3'), '原画', 's_999'),
        (SpiderSite(key: 'nodejs_ouge', name: '「盘」欧歌', api: '/spider/ouge/3'), '线路1', 's_888'),
        (site, '夸克网盘', 'https://pan.quark.cn/s/abc'),
        (site, 'UC网盘', 'https://drive.uc.cn/s/xyz'),
        (site, '123云盘', 'https://www.123pan.cn/s/abc'),
        (site, '线路一', 'push://https://example.com/v.mp4'),
        (site, '配置入口', 'http://127.0.0.1:9321/web'),
      ]) {
        expect(
          VodEpisodePrewarmCache.canWarmupSpiderEpisode(site: panSite, lineName: lineName, episodeUrl: epUrl),
          isFalse,
          reason: 'must never pre-trigger cloud-drive or web entry: $lineName / $epUrl',
        );
      }

      var playCalls = 0;
      final api = _DelayedPlayApi(() async {
        playCalls++;
        await Future<void>.delayed(const Duration(milliseconds: 90));
        return PlayResult(url: 'http://127.0.0.1:${mediaServer.port}/vertical.m3u8');
      });
      final prewarmedDetail = makeDetail('prewarmed_drama');
      VodEpisodePrewarmCache.shared.warmUp(
        site: site,
        api: api,
        lineName: '线路一',
        episodeUrl: 'v1',
        memoryKey: vodKey(site.key, prewarmedDetail.item.id),
      );
      await Future<void>.delayed(const Duration(milliseconds: 180));
      expect(playCalls, 1);

      final router = PlayerSessionRouter();
      final host = _RecordingHost(router: router);
      final launcher = buildLauncher(host, router, budget: const Duration(milliseconds: 50));
      final sw = Stopwatch()..start();
      final playFuture = launcher.play(site: site, api: api, detail: prewarmedDetail, history: history);
      while (host.opened.isEmpty && sw.elapsedMilliseconds < 200) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(playCalls, 1, reason: '立即播放 reuses prewarmed PlayResult without calling spider.play again');
      expect(host.opened.single.initialSource?.videoWidth, 1080);
      expect(host.opened.single.initialSource?.videoHeight, 1920);

      await router.onPageClosed(
          PageClosedEvent(sessionId: host.opened.single.sessionId, positionSeconds: 1, completed: false));
      await playFuture;
    });

    test('decoder onVideoSizeDetected remembers encrypted VOD dimensions per-VOD without polluting other VODs on same site',
        () async {
      final router = PlayerSessionRouter();
      final host = _RecordingHost(router: router);
      final launcher = buildLauncher(host, router, budget: const Duration(milliseconds: 80));
      final encDetail = makeDetail('enc_drama');
      final api = _DelayedPlayApi(
          () async => PlayResult(url: 'http://127.0.0.1:${mediaServer.port}/encrypted_only.m3u8'));

      // 1. First open of encrypted vertical drama: probe returns null -> opens in default landscape first.
      final f1 = launcher.play(site: site, api: api, detail: encDetail, history: history, episode: 0);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final open1 = host.opened.single;
      expect(open1.initialSource?.videoWidth, isNull);

      // Native decoder decrypts frame 1 (720x1280) and reports back to Dart.
      await router.onVideoSizeDetected(open1.sessionId, 0, 0, 720, 1280);
      await router.onPageClosed(PageClosedEvent(sessionId: open1.sessionId, positionSeconds: 12, completed: false));
      await f1;

      final savedHistory = await history.find(site.key, encDetail.item.id);
      expect((savedHistory?.videoWidth, savedHistory?.videoHeight), (720, 1280));

      // 2. Episode 2 of the SAME encrypted VOD (even on slow resolve!) immediately carries portrait fallback (720x1280).
      final slowApi = _DelayedPlayApi(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return PlayResult(url: 'http://127.0.0.1:${mediaServer.port}/encrypted_only.m3u8?ep=2');
      });
      final f2 = launcher.play(site: site, api: slowApi, detail: encDetail, history: history, episode: 1);
      await Future<void>.delayed(const Duration(milliseconds: 110));
      expect(host.opened, hasLength(2));
      final open2 = host.opened[1];
      expect((open2.initialVideoWidth, open2.initialVideoHeight), (720, 1280));
      await router.onPageClosed(PageClosedEvent(sessionId: open2.sessionId, positionSeconds: 5, completed: false));
      await f2;

      // 3. A DIFFERENT unknown VOD on the SAME siteKey must NOT inherit portrait (no site-level pollution).
      final otherDetail = makeDetail('other_horizontal_movie');
      final f3 = launcher.play(site: site, api: slowApi, detail: otherDetail, history: history, episode: 0);
      await Future<void>.delayed(const Duration(milliseconds: 110));
      expect(host.opened, hasLength(3));
      final open3 = host.opened[2];
      expect(open3.initialSource, isNull);
      expect(open3.initialVideoWidth, isNull, reason: 'must prioritize landscape for unknown VOD on same site');
      await router.onPageClosed(PageClosedEvent(sessionId: open3.sessionId, positionSeconds: 0, completed: false));
      await f3;
    });

    test('isCancelled aborts opening player both before open and mid-way through native onProbeVideoSize', () async {
      final router = PlayerSessionRouter();
      final host = _RecordingHost(router: router);
      final launcher = buildLauncher(host, router, budget: const Duration(milliseconds: 220));
      var cancelled = false;
      final api = _DelayedPlayApi(() async => PlayResult(url: 'http://127.0.0.1:${mediaServer.port}/slow_vertical.m3u8'));

      final playFut = launcher.play(
        site: site,
        api: api,
        detail: makeDetail('cancelled_mid_probe'),
        history: history,
        isCancelled: () => cancelled,
      );
      // User navigates back 40ms after clicking play while header probe is in flight.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      cancelled = true;
      final event = await playFut;
      expect(host.opened, isEmpty, reason: 'native player must not pop open after user navigated back');
      expect(event.positionSeconds, 0);
    });

    test('Emby MediaItem & PlaybackInfo rotated video streams populate portrait dimensions with zero extra probe',
        () async {
      final parsedItem = MediaItem.fromJson({
        'Id': 'item1',
        'Name': 'Clip',
        'Type': 'Movie',
        'MediaStreams': [
          {'Type': 'Video', 'Width': 1920, 'Height': 1080, 'Rotation': 270},
        ],
      });
      expect((parsedItem.videoWidth, parsedItem.videoHeight), (1080, 1920));

      final dio = Dio()
        ..httpClientAdapter = _FakeDioAdapter({
          'MediaSources': [
            {
              'MediaStreams': [
                {'Type': 'Audio', 'Codec': 'aac'},
                {'Type': 'Video', 'Width': 1920, 'Height': 1080, 'Rotation': 90},
              ],
            },
          ],
        });
      final client = MediaServerClient(
        const MediaAccount(id: 'a1', name: 'Emby', baseUrl: 'http://emby:8096', userId: 'u1', token: 't1'),
        dio: dio,
      );
      final src = MediaServerPlaybackSource(
        client: client,
        title: 'Vertical Clip',
        items: [parsedItem],
      );
      expect(await src.fallbackDimensions(0, 0), (width: 1080, height: 1920));
      final res = await src.resolve(0, 0);
      expect((res.videoWidth, res.videoHeight), (1080, 1920));
    });

    test('Live TV channels with EPG skip HTTP format probing so single-connection IPTV tokens are untouched', () async {
      var probeRequests = 0;
      final iptvServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => iptvServer.close(force: true));
      iptvServer.listen((req) async {
        probeRequests++;
        req.response.write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=720x1280\nhigh.m3u8\n');
        await req.response.close();
      });

      final router = PlayerSessionRouter();
      final host = _RecordingHost(router: router);
      final launcher = buildLauncher(host, router);
      final liveSource = DirectPlaybackSource(
        title: 'CCTV-1',
        lines: [
          PlayLine('央视', [PlayEpisode('CCTV-1', 'http://127.0.0.1:${iptvServer.port}/live.m3u8')])
        ],
        epg: [EpgProgramme(startEpochMs: 1000, endEpochMs: 2000, title: 'News')],
      );

      final playFuture = launcher.playSource(liveSource);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(host.opened, hasLength(1));
      expect(probeRequests, 0, reason: 'Live TV must not issue a duplicate HTTP probe connection');

      await router.onPageClosed(
          PageClosedEvent(sessionId: host.opened.single.sessionId, positionSeconds: 0, completed: false));
      await playFuture;
    });

    test('VodEpisodePrewarmCache resolves spider api.play even for direct .m3u8 episodeUrl, keeps anti-hotlink headers, and survives repeat opens',
        () async {
      final guardedServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => guardedServer.close(force: true));
      guardedServer.listen((req) async {
        if (req.headers.value('referer') != 'https://cms.example/play') {
          req.response.statusCode = HttpStatus.forbidden;
          await req.response.close();
          return;
        }
        req.response
          ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
          ..write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=1080x1920\nhigh.m3u8\n');
        await req.response.close();
      });

      const directEpUrl = 'https://cdn.cms.example/2026/cms_direct.m3u8';
      final resolvedUrl = 'http://127.0.0.1:${guardedServer.port}/cms_direct.m3u8';
      expect(VideoFormatProbe.isDirectWarmupCandidate(directEpUrl), isTrue);

      var playCalls = 0;
      final api = _DelayedPlayApi(() async {
        playCalls++;
        return PlayResult(url: resolvedUrl, headers: const {'Referer': 'https://cms.example/play'});
      });
      final cmsDetail = VodDetail(
        item: VodItem(id: 'cms_1', name: '苹果CMS短剧', siteKey: site.key),
        lines: const [
          PlayLine('高清m3u8', [PlayEpisode('第1集', directEpUrl)]),
        ],
      );
      final probe = VideoFormatProbe(httpClientFactory: HttpClient.new);
      addTearDown(probe.close);

      VodEpisodePrewarmCache.shared.warmUp(
        site: site,
        api: api,
        lineName: '高清m3u8',
        episodeUrl: directEpUrl,
        memoryKey: vodKey(site.key, cmsDetail.item.id),
        probe: probe,
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(playCalls, 1, reason: 'warmUp must call api.play to obtain PlayResult + anti-hotlink headers');
      expect(probe.cachedVod(vodKey(site.key, cmsDetail.item.id)), (width: 1080, height: 1920));

      final router = PlayerSessionRouter();
      final host = _RecordingHost(router: router);
      final launcher = PlayerLauncher(
        configs: PlayerConfigRepository(store: JsonStore('player_config.json', baseDir: dir)),
        sniffer: SnifferService(),
        host: host,
        router: router,
        formatProbe: probe,
        fastLaunchBudget: const Duration(milliseconds: 50),
        installRouter: false,
        enableWakelock: () async {},
        disableWakelock: () async {},
      );

      // 1st click on 立即播放: 0 extra api.play calls, opens directly in portrait!
      final f1 = launcher.play(site: site, api: api, detail: cmsDetail, history: history);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(playCalls, 1);
      expect((host.opened.last.initialSource?.videoWidth, host.opened.last.initialSource?.videoHeight), (1080, 1920));
      await router.onPageClosed(
          PageClosedEvent(sessionId: host.opened.last.sessionId, positionSeconds: 5, completed: false));
      await f1;

      // 2nd click after returning to DetailScreen: unexpired cache is NOT destroyed, still 0 extra api.play calls!
      final f2 = launcher.play(site: site, api: api, detail: cmsDetail, history: history);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(playCalls, 1, reason: 'returning to DetailScreen and clicking 立即播放 again must reuse unexpired cache');
      expect((host.opened.last.initialSource?.videoWidth, host.opened.last.initialSource?.videoHeight), (1080, 1920));

      // Simulate fatal playback error -> cache invalidated so subsequent retry calls api.play fresh!
      await router.onErrorReported(
          ErrorReport(sessionId: host.opened.last.sessionId, message: 'HTTP 403', fatal: true));
      await router.onPageClosed(
          PageClosedEvent(sessionId: host.opened.last.sessionId, positionSeconds: 5, completed: false));
      await f2;

      final f3 = launcher.play(site: site, api: api, detail: cmsDetail, history: history);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(playCalls, 2, reason: 'error invalidates cached PlayResult so retry fetches a fresh URL');
      await router.onPageClosed(
          PageClosedEvent(sessionId: host.opened.last.sessionId, positionSeconds: 5, completed: false));
      await f3;
    });

    test('resolves fast probe directly in Dart without Native onProbeVideoSize RTT, and pushes background size when slow on non-fast-probe host',
        () async {
      final router = PlayerSessionRouter();
      // Pass router: null so _RecordingHost never calls onProbeVideoSize.
      final hostWithoutFastProbe = _RecordingHost();
      final fastLauncher = buildLauncher(hostWithoutFastProbe, router, budget: const Duration(milliseconds: 300));
      final fastApi = _DelayedPlayApi(() async => PlayResult(url: 'http://127.0.0.1:${mediaServer.port}/vertical.m3u8'));

      final f1 = fastLauncher.play(site: site, api: fastApi, detail: makeDetail('direct_dart_probe_ep'), history: history);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(hostWithoutFastProbe.opened, hasLength(1));
      final openedFast = hostWithoutFastProbe.opened.single;
      // Populated directly in Dart before openPlayerPage, with zero Native -> Dart -> Native round-trips!
      expect((openedFast.initialSource?.videoWidth, openedFast.initialSource?.videoHeight), (1080, 1920));
      expect(openedFast.probeBudgetMs, 0);
      await router.onPageClosed(PageClosedEvent(sessionId: openedFast.sessionId, positionSeconds: 2, completed: false));
      await f1;

      // Slow probe (180ms > 60ms budget) on a host that skips onProbeVideoSize still pushes updateVideoSize in background.
      final slowLauncher = buildLauncher(hostWithoutFastProbe, router, budget: const Duration(milliseconds: 60));
      final slowApi =
          _DelayedPlayApi(() async => PlayResult(url: 'http://127.0.0.1:${mediaServer.port}/slow_vertical.m3u8'));
      final f2 = slowLauncher.play(site: site, api: slowApi, detail: makeDetail('non_phone_slow_ep'), history: history);
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(hostWithoutFastProbe.opened, hasLength(2));
      final openedSlow = hostWithoutFastProbe.opened.last;
      expect(openedSlow.initialSource?.videoWidth, isNull);

      await Future<void>.delayed(const Duration(milliseconds: 180));
      expect(hostWithoutFastProbe.videoSizes, [(openedSlow.sessionId, 0, 0, 720, 1280)]);

      await router.onPageClosed(PageClosedEvent(sessionId: openedSlow.sessionId, positionSeconds: 2, completed: false));
      await f2;
    });
  });
}

class _BitWriter {
  final List<int> _bytes = [];
  int _cur = 0;
  int _bitsInCur = 0;

  void writeBit(int bit) {
    _cur = (_cur << 1) | (bit & 1);
    _bitsInCur++;
    if (_bitsInCur == 8) {
      _bytes.add(_cur);
      _cur = 0;
      _bitsInCur = 0;
    }
  }

  void writeBits(int value, int count) {
    for (var i = count - 1; i >= 0; i--) {
      writeBit((value >> i) & 1);
    }
  }

  void writeUe(int value) {
    final code = value + 1;
    var bits = 0;
    var tmp = code;
    while (tmp > 0) {
      bits++;
      tmp >>= 1;
    }
    final zeros = bits - 1;
    for (var i = 0; i < zeros; i++) {
      writeBit(0);
    }
    writeBits(code, bits);
  }

  Uint8List toRbspNal({int headerBytes = 1}) {
    if (_bitsInCur > 0) {
      _bytes.add(_cur << (8 - _bitsInCur));
      _cur = 0;
      _bitsInCur = 0;
    }
    final out = <int>[];
    for (var i = 0; i < headerBytes && i < _bytes.length; i++) {
      out.add(_bytes[i]);
    }
    var zeros = 0;
    for (var i = headerBytes; i < _bytes.length; i++) {
      final b = _bytes[i];
      if (zeros >= 2 && b <= 3) {
        out.add(0x03);
        zeros = 0;
      }
      out.add(b);
      zeros = b == 0 ? zeros + 1 : 0;
    }
    return Uint8List.fromList(out);
  }
}
