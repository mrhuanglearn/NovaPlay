import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import '../app/theme.dart';
import '../app/ui_hooks.dart';
import '../core/haptics.dart';
import '../features/catpaw/catpaw_protocol.dart';
import '../features/danmaku/danmu_service.dart';
import '../features/player/native_player_api.g.dart';
import '../l10n/l10n.dart';
import 'form_widgets.dart';
import 'widgets.dart';

/// Grey explanatory text under a settings card.
class SettingsNote extends StatelessWidget {
  const SettingsNote(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        child: Text(text, style: TextStyle(fontSize: 12.5, color: AppColors.of(context).secondaryLabel)),
      );
}

/// `/settings/player`. Every change is written immediately to `player_config.json`.
class PlayerSettingsScreen extends ConsumerStatefulWidget {
  const PlayerSettingsScreen({super.key});
  @override
  ConsumerState<PlayerSettingsScreen> createState() => _PlayerSettingsScreenState();
}

class _PlayerSettingsScreenState extends ConsumerState<PlayerSettingsScreen> {
  PlaybackConfig? _p;
  DanmakuConfig? _d;
  final _subLang = TextEditingController();
  final _font = TextEditingController();
  final _fontsDir = TextEditingController();
  final _audioLang = TextEditingController();

  @override
  void initState() {
    super.initState();
    ref.read(playerConfigRepositoryProvider).load().then((v) {
      if (!mounted) return;
      final (p, d) = v;
      _subLang.text = p.subtitleLang ?? '';
      _font.text = p.subtitleFontFamily ?? '';
      _fontsDir.text = p.subtitleFontsDir ?? '';
      _audioLang.text = p.audioLang ?? '';
      setState(() {
        _p = p;
        _d = d;
      });
    });
  }

  @override
  void dispose() {
    for (final c in [_subLang, _font, _fontsDir, _audioLang]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Writes only when the text actually changed: every write moves the file's mtime, which WebDAV sync reads.
  void _commit(String? current, String text, void Function(PlaybackConfig p, String? v) apply) {
    final v = text.trim().isEmpty ? null : text.trim();
    if (v == current) return;
    _change((p) => apply(p, v));
  }

  void _change(void Function(PlaybackConfig p) edit) {
    final p = _p!;
    setState(() => edit(p));
    ref.read(playerConfigRepositoryProvider).save(p, _d!);
  }

  Future<void> _pick<T>(
      String title, T current, Map<T, String> options, void Function(PlaybackConfig p, T v) apply) async {
    final v = await showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(title,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.of(sheet).label)),
          ),
          for (final e in options.entries)
            ListTile(
              title: Text(e.value),
              trailing: e.key == current ? Icon(Icons.check, color: AppColors.of(context).accent) : null,
              onTap: () => Navigator.pop(sheet, e.key),
            ),
        ]),
      ),
    );
    if (v != null && v != current) _change((p) => apply(p, v));
  }

  static String _num(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(1) : '${double.parse(v.toStringAsFixed(2))}';

  static String _normalizeIosKernel(String raw) => switch (raw.trim().toLowerCase()) {
        'mpv' => 'mpv',
        'vlc' || 'mdk' => 'vlc',
        _ => 'avplayer',
      };

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final l = context.l10n;
    final isIos = Theme.of(context).platform == TargetPlatform.iOS;
    // OBSERVED (UZN 1.1.7 on Android, 2026-11-10): MPV (MPV) / MDK (MDK) / EXO (SYSTEM).
    // On iOS 15+, expose 3 native kernels: AVPlayer (VideoToolbox + PiP + AirPlay), MPV (libmpv + Metal/MoltenVK), and VLC (MobileVLCKit / FFmpeg).
    final kernels = isIos
        ? const {'avplayer': 'AVPlayer (SYSTEM)', 'mpv': 'MPV (MPV)', 'vlc': 'VLC (FFmpeg)'}
        : const {'mpv': 'MPV (MPV)', 'mdk': 'MDK (MDK)', 'exo': 'EXO (SYSTEM)'};
    final kernelNames = isIos
        ? const {'avplayer': 'AVPlayer', 'mpv': 'MPV', 'vlc': 'VLC'}
        : const {'mpv': 'MPV', 'mdk': 'MDK', 'exo': 'EXO'};
    final effectiveKernel = p == null ? '' : (isIos ? _normalizeIosKernel(p.kernel) : p.kernel);
    final fits = {'fit': l.playerFitFit, 'zoom': l.playerFitZoom, 'fill': l.playerFitFill};
    // OBSERVED (播放器): 解码 / 画面与内核 / 播放 / 信息显示, steppers for the speeds and the seek step. 字幕与音频 is this
    // project's own section (the original has 字幕样式 colours there). The player page's gear shows these same rows in the
    // same order (android/.../ui/PlayerSettings.kt; test/player_settings_parity_test.dart).
    return Scaffold(
      appBar: AppBar(title: Text(l.settingsPlayer)),
      body: p == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: EdgeInsets.only(bottom: 32 + MediaQuery.paddingOf(context).bottom), children: [
              SettingsSection(title: l.playerGroupDecode, children: [
                SwitchRow(
                  icon: Icons.memory,
                  title: l.playerHwDecode,
                  subtitle: (isIos && effectiveKernel == 'avplayer') ? l.playerHwDecodeIosAvSub : l.playerHwDecodeSub,
                  value: p.hwDecode,
                  onChanged: (v) => _change((p) => p.hwDecode = v),
                ),
              ]),
              SettingsSection(title: l.playerGroupPicture, children: [
                SettingsTile(
                  icon: Icons.view_module_outlined,
                  title: l.playerKernel,
                  subtitle: kernelNames[effectiveKernel] ?? effectiveKernel.toUpperCase(),
                  onTap: () => _pick<String>(l.playerKernel, effectiveKernel, kernels, (p, v) => p.kernel = v),
                ),
                SettingsTile(
                  icon: Icons.aspect_ratio,
                  title: l.playerFit,
                  subtitle: fits[p.fitMode] ?? p.fitMode,
                  onTap: () => _pick<String>(l.playerFit, p.fitMode, fits, (p, v) => p.fitMode = v),
                ),
              ]),
              if (!isIos && p.kernel == 'mpv') SettingsNote(l.playerMpvNote),
              if (!isIos && p.kernel == 'mdk') SettingsNote(l.playerMdkNote),
              if (isIos && effectiveKernel == 'avplayer') SettingsNote(l.playerIosAvplayerNote),
              if (isIos && effectiveKernel == 'mpv') SettingsNote(l.playerIosMpvNote),
              if (isIos && effectiveKernel == 'vlc') SettingsNote(l.playerIosVlcNote),
              SettingsSection(title: l.playerGroupPlayback, children: [
                SettingsTile(
                  icon: Icons.speed,
                  title: l.playerDefaultSpeed,
                  trailing: ValueStepper(
                    value: _num(p.speed),
                    onMinus: p.speed <= 0.25 ? null : () => _change((p) => p.speed = (p.speed - 0.25).clamp(0.25, 4)),
                    onPlus: p.speed >= 4 ? null : () => _change((p) => p.speed = (p.speed + 0.25).clamp(0.25, 4)),
                  ),
                ),
                SettingsTile(
                  icon: Icons.fast_forward,
                  title: l.playerDoubleTapSeek,
                  trailing: ValueStepper(
                    value: '${p.fastForwardSeconds}',
                    onMinus: p.fastForwardSeconds <= 5 ? null : () => _change((p) => p.fastForwardSeconds -= 5),
                    onPlus: p.fastForwardSeconds >= 120 ? null : () => _change((p) => p.fastForwardSeconds += 5),
                  ),
                ),
                SettingsTile(
                  icon: Icons.touch_app_outlined,
                  title: l.playerLongPressSpeed,
                  trailing: ValueStepper(
                    value: _num(p.longPressSpeed),
                    onMinus: p.longPressSpeed <= 1.5
                        ? null
                        : () => _change((p) => p.longPressSpeed = (p.longPressSpeed - 0.5).clamp(1.5, 5)),
                    onPlus: p.longPressSpeed >= 5
                        ? null
                        : () => _change((p) => p.longPressSpeed = (p.longPressSpeed + 0.5).clamp(1.5, 5)),
                  ),
                ),
                SwitchRow(
                  icon: Icons.swipe_vertical_outlined,
                  title: l.playerLongPressSpeedAdjust,
                  subtitle: l.playerLongPressSpeedAdjustSub,
                  value: p.isLongPressSpeedAdjustEnabled != false,
                  onChanged: (v) => _change((p) => p.isLongPressSpeedAdjustEnabled = v),
                ),
                SwitchRow(
                    icon: Icons.crop_landscape,
                    title: l.playerPreferLandscape,
                    value: p.isPriorityLandscape,
                    onChanged: (v) => _change((p) => p.isPriorityLandscape = v)),
                SwitchRow(
                  icon: Icons.timer_outlined,
                  title: l.playerShowTotalDuration,
                  subtitle: l.playerShowTotalDurationSub,
                  value: p.isShowAllDuration,
                  onChanged: (v) => _change((p) => p.isShowAllDuration = v),
                ),
                SwitchRow(
                    icon: Icons.skip_next_outlined,
                    title: l.playerHideSeekButtons,
                    value: p.isHiddenFastSeekBtn,
                    onChanged: (v) => _change((p) => p.isHiddenFastSeekBtn = v)),
                SwitchRow(
                    icon: Icons.picture_in_picture_alt_outlined,
                    title: l.playerPauseInBackground,
                    value: p.pauseOnBackground,
                    onChanged: (v) => _change((p) => p.pauseOnBackground = v)),
                SwitchRow(
                  icon: Icons.picture_in_picture_alt_outlined,
                  title: l.playerAutoPip,
                  subtitle: (isIos && effectiveKernel != 'avplayer') ? l.playerAutoPipIosVlcSub : l.playerAutoPipSub,
                  value: p.autoPictureInPicture,
                  onChanged: (v) => _change((p) => p.autoPictureInPicture = v),
                ),
                SwitchRow(
                  icon: Icons.notifications_active_outlined,
                  title: l.playerSkipNotice,
                  subtitle: l.playerSkipNoticeSub,
                  value: p.skipNotice,
                  onChanged: (v) => _change((p) => p.skipNotice = v),
                ),
                SwitchRow(
                  icon: Icons.queue_play_next,
                  title: l.playerEpisodeSwitchNotice,
                  subtitle: l.playerEpisodeSwitchNoticeSub,
                  value: p.isShowEpisodeSwitchNotice,
                  onChanged: (v) => _change((p) => p.isShowEpisodeSwitchNotice = v),
                ),
              ]),
              SettingsSection(title: l.playerGroupOverlay, children: [
                SwitchRow(
                  icon: Icons.bar_chart,
                  title: l.playerShowStats,
                  subtitle: l.playerShowStatsSub,
                  value: p.isShowStatsBar,
                  onChanged: (v) => _change((p) => p.isShowStatsBar = v),
                ),
                SwitchRow(
                  icon: Icons.network_check,
                  title: l.playerShowNetSpeed,
                  subtitle: l.playerShowNetSpeedSub,
                  value: p.showNetSpeed,
                  onChanged: (v) => _change((p) => p.showNetSpeed = v),
                ),
              ]),
              SettingsSection(title: l.playerGroupSubtitles, children: [
                CommitTextRow(
                  controller: _subLang,
                  label: l.playerSubtitleLang,
                  hint: 'zh, en, ja ...',
                  onCommit: (t) => _commit(_p!.subtitleLang, t, (p, v) => p.subtitleLang = v),
                ),
                CommitTextRow(
                  controller: _font,
                  label: l.playerSubtitleFont,
                  hint: isIos ? l.playerSubtitleFontHintIos : l.playerSubtitleFontHint,
                  onCommit: (t) => _commit(_p!.subtitleFontFamily, t, (p, v) => p.subtitleFontFamily = v),
                ),
                if (!isIos)
                  CommitTextRow(
                    controller: _fontsDir,
                    label: l.playerFontsDir,
                    hint: '/storage/emulated/0/Fonts',
                    onCommit: (t) => _commit(_p!.subtitleFontsDir, t, (p, v) => p.subtitleFontsDir = v),
                  ),
                CommitTextRow(
                  controller: _audioLang,
                  label: l.playerAudioLang,
                  hint: 'ja, en, zh ...',
                  onCommit: (t) => _commit(_p!.audioLang, t, (p, v) => p.audioLang = v),
                ),
              ]),
              SettingsNote(isIos ? l.playerSubtitleNoteIos : l.playerSubtitleNote),
              SettingsNote(l.playerReloadNote),
            ]),
    );
  }
}

/// `/settings/danmu` (OBSERVED 弹幕服务): 启用弹幕 + 弹幕服务来源 (本地服务 / 订阅自带 / 自定义远程); for 本地服务 a card with
/// 运行状态 / 测试连通, 打开网页 / 重启服务 / 关闭服务, 网络订阅源 (.cjs.md5 + 下载脚本) or 本地脚本, and 端口; then the display
/// settings. Everything below the switch is dimmed while danmaku is off. Changes are saved at once (no save button).
/// Not reproduced: 优先使用视频返回弹幕数据, 字体粗细, the 渐变 colour style.
class DanmuSettingsScreen extends ConsumerStatefulWidget {
  const DanmuSettingsScreen({super.key});
  @override
  ConsumerState<DanmuSettingsScreen> createState() => _DanmuSettingsScreenState();
}

class _DanmuSettingsScreenState extends ConsumerState<DanmuSettingsScreen> {
  final _remote = TextEditingController();
  final _script = TextEditingController();
  DanmuServiceConfig? _cfg;
  PlaybackConfig? _p;
  DanmakuConfig? _d;
  CatpawInstance? _status;
  bool _hasScript = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  DanmuServiceController get _ctl => ref.read(danmuServiceControllerProvider);

  Future<void> _load() async {
    final cfg = await _ctl.config();
    final (p, d) = await ref.read(playerConfigRepositoryProvider).load();
    final has = await _ctl.hasScript();
    if (!mounted) return;
    setState(() {
      _cfg = cfg;
      _remote.text = cfg.remoteUrl;
      _script.text = cfg.scriptUrl;
      _p = p;
      _d = d;
      _hasScript = has;
    });
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    if (_cfg?.source != DanmuMode.builtin) return;
    try {
      final s = await _ctl.builtinStatus().timeout(const Duration(seconds: 8));
      if (mounted) setState(() => _status = s);
    } catch (_) {}
  }

  @override
  void dispose() {
    for (final c in [_remote, _script]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _saveCfg(DanmuServiceConfig c) async {
    setState(() => _cfg = c);
    await _ctl.save(c);
  }

  void _appearance(void Function(DanmakuConfig d) edit) {
    setState(() => edit(_d!));
    ref.read(playerConfigRepositoryProvider).save(_p!, _d!);
  }

  Future<void> _run(Future<String?> Function() job) async {
    setState(() => _busy = true);
    try {
      final msg = await job();
      if (msg != null) showToast(msg);
    } catch (e) {
      showToast(e is StateError ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refreshStatus();
    }
  }

  Future<String?> _test() async {
    final l = context.l10n;
    await _ctl.save(_cfg!);
    final client = await _ctl.resolve();
    if (client == null) return l.danmuNotReachable;
    final found = await client.searchAnime('a');
    return l.danmuReachable(found.length);
  }

  Future<void> _pickLocal() async {
    final l = context.l10n;
    final f = await FilePicker.pickFile(type: FileType.any);
    if (f == null) return;
    if (!RegExp(r'\.(cjs|js)$', caseSensitive: false).hasMatch(f.name)) return showToast(l.danmuLocalOnlyCjs(f.name));
    await _run(() async {
      await _ctl.importScript(await f.readAsBytes());
      await _saveCfg(_cfg!.copyWith(localScript: true));
      _hasScript = true;
      if (_status?.running ?? false) await _ctl.restartBuiltin(_cfg!);
      return l.danmuLocalLoaded;
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final cfg = _cfg;
    final l = context.l10n;
    final c = AppColors.of(context);
    if (d == null || cfg == null) {
      return Scaffold(
          appBar: AppBar(title: Text(l.settingsDanmu)), body: const Center(child: CircularProgressIndicator()));
    }
    final on = cfg.enabled;
    final running = _status?.running ?? false;
    final secondary = FilledButton.styleFrom(
      backgroundColor: c.cardHigh,
      foregroundColor: c.label,
      minimumSize: const Size(double.infinity, 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    );
    Widget dim(Widget child) => IgnorePointer(ignoring: !on, child: Opacity(opacity: on ? 1 : 0.38, child: child));
    String fixed(double v, int digits) => v.toStringAsFixed(digits);

    final service = switch (cfg.source) {
      DanmuMode.builtin => SettingsSection(children: [
          SettingsTile(
            icon: Icons.bolt,
            title: l.danmuStatus,
            subtitle: running ? l.danmuRunning('${_status?.port ?? cfg.port}') : l.danmuStopped,
            trailing: TextButton(
              style: TextButton.styleFrom(foregroundColor: c.label),
              onPressed: _busy ? null : () => _run(_test),
              child: Text(l.testConnection),
            ),
          ),
          if (!_hasScript) SettingsTile(icon: Icons.add, title: l.danmuNoService, subtitle: l.danmuNoServiceSub),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: Column(children: [
              FilledButton(
                style: secondary,
                onPressed: _busy
                    ? null
                    : () {
                        if (!running) return showToast(l.danmuNotReady);
                        context.push(Uri(
                            path: '/website',
                            queryParameters: {'url': 'http://127.0.0.1:${_status?.port ?? cfg.port}/'}).toString());
                      },
                child: Text(l.danmuOpenWeb),
              ),
              const SizedBox(height: 8),
              FilledButton(
                style: secondary,
                onPressed: _busy ? null : () => _run(() async => _ctl.restartBuiltin(cfg).then((_) => null)),
                child: Text(l.danmuRestart),
              ),
              const SizedBox(height: 4),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: c.label, minimumSize: const Size(double.infinity, 40)),
                onPressed: _busy || !running ? null : () => _run(() async => _ctl.stopBuiltin().then((_) => null)),
                child: Text(l.danmuStop),
              ),
              const SizedBox(height: 6),
              AppSegmented<bool>(
                onCard: true,
                value: cfg.localScript,
                onChanged: (v) => _saveCfg(cfg.copyWith(localScript: v)),
                segments: {
                  false: (Icons.language, l.danmuNetworkSource),
                  true: (Icons.folder_outlined, l.danmuLocalScriptTab)
                },
              ),
            ]),
          ),
          if (!cfg.localScript) ...[
            CommitTextRow(
              controller: _script,
              label: l.danmuSourceUrl,
              hint: 'https://user:pass@host/server.cjs.md5',
              onCommit: (t) => _saveCfg(cfg.copyWith(scriptUrl: t.trim())),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: FilledButton(
                style: secondary,
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                          final next = cfg.copyWith(scriptUrl: _script.text.trim(), localScript: false);
                          await _saveCfg(next);
                          final md5 = await _ctl.updateScript(next);
                          _hasScript = true;
                          if (running) await _ctl.restartBuiltin(next);
                          return l.danmuScriptDownloaded(md5);
                        }),
                child: Text(l.danmuDownload),
              ),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
              child: FilledButton(
                  style: secondary,
                  onPressed: _busy ? null : _pickLocal,
                  child: Text(_hasScript ? l.danmuReplaceLocal : l.danmuLoadLocal)),
            ),
          SettingsTile(
            icon: Icons.adjust,
            title: l.port,
            trailing: ValueStepper(
              value: '${cfg.port}',
              onMinus: cfg.port <= 1024 ? null : () => _saveCfg(cfg.copyWith(port: cfg.port - 1)),
              onPlus: cfg.port >= 65535 ? null : () => _saveCfg(cfg.copyWith(port: cfg.port + 1)),
            ),
          ),
        ]),
      DanmuMode.remote => SettingsSection(children: [
          CommitTextRow(
            controller: _remote,
            label: l.serverAddress,
            hint: l.danmuRemoteHint,
            onCommit: (t) => _saveCfg(cfg.copyWith(remoteUrl: t.trim())),
          ),
          SettingsTile(
            icon: Icons.bolt,
            title: l.testConnection,
            onTap: _busy
                ? null
                : () => _run(() async {
                      await _saveCfg(cfg.copyWith(remoteUrl: _remote.text.trim()));
                      return _test();
                    }),
          ),
        ]),
      _ => SettingsSection(children: [
          SettingsTile(
              icon: Icons.cloud_outlined, title: l.danmuModeSubscription, subtitle: l.danmuModeSubscriptionNote),
          SettingsTile(icon: Icons.bolt, title: l.testConnection, onTap: _busy ? null : () => _run(_test)),
        ]),
    };

    return Scaffold(
      appBar: AppBar(title: Text(l.settingsDanmu)),
      body: ListView(padding: EdgeInsets.only(bottom: 32 + MediaQuery.paddingOf(context).bottom), children: [
        SettingsSection(children: [
          SwitchRow(
            icon: Icons.subtitles_outlined,
            title: l.danmuEnable,
            value: on,
            onChanged: (v) {
              _appearance((d) => d.enabled = v);
              _saveCfg(cfg.copyWith(enabled: v, mode: cfg.source));
              if (v) _refreshStatus();
            },
          ),
          dim(Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.danmuSource, style: TextStyle(fontSize: 13, color: c.subtitle)),
              const SizedBox(height: 8),
              AppSegmented<DanmuMode>(
                onCard: true,
                value: cfg.source,
                onChanged: (v) {
                  _saveCfg(cfg.copyWith(mode: v));
                  _refreshStatus();
                },
                segments: {
                  DanmuMode.builtin: (Icons.play_circle_outline, l.danmuModeBuiltin),
                  DanmuMode.subscription: (Icons.cloud_outlined, l.danmuModeSubscription),
                  DanmuMode.remote: (Icons.dns_outlined, l.danmuModeRemote),
                },
              ),
            ]),
          )),
        ]),
        dim(service),
        dim(SettingsSection(children: [
          SwitchRow(
            icon: Icons.bolt_outlined,
            title: '优先使用视频返回弹幕数据',
            subtitle: '视频接口返回弹幕地址或数据时优先使用，否则请求弹幕服务',
            value: cfg.preferVideoDanmu,
            onChanged: (v) => _saveCfg(cfg.copyWith(preferVideoDanmu: v)),
          ),
        ])),
        dim(SettingsSection(children: [
          SwitchRow(
              icon: Icons.vertical_align_top,
              title: l.danmuShowTop,
              subtitle: l.danmuShowPositionSub,
              value: d.showTop,
              onChanged: (v) => _appearance((d) => d.showTop = v)),
          SwitchRow(
            icon: Icons.vertical_align_bottom,
            title: l.danmuShowBottom,
            subtitle: l.danmuShowPositionSub,
            value: d.showBottom,
            onChanged: (v) => _appearance((d) => d.showBottom = v),
          ),
          SettingsTile(
            icon: Icons.palette_outlined,
            title: l.danmuColor,
            subtitle: switch (d.colorMode) {
              'random_Mix' || '0' => '随机（混渐变）',
              'white' || '1' => l.danmuColorWhite,
              'gradient' || '3' => '全部渐变',
              'random' || 'random_Color' || '4' => l.danmuColorRandom,
              _ => l.danmuColorOriginal,
            },
            onTap: () async {
              final modes = [
                ('random_Mix', '随机（混渐变）'),
                ('white', l.danmuColorWhite),
                ('original', l.danmuColorOriginal),
                ('gradient', '全部渐变'),
                ('random', l.danmuColorRandom),
              ];
              final v = await showModalBottomSheet<String>(
                context: context,
                showDragHandle: true,
                builder: (sheet) => SafeArea(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    for (final (k, label) in modes)
                      ListTile(
                        title: Text(label),
                        trailing: d.colorMode == k
                            ? Icon(Icons.check, color: AppColors.of(context).accent)
                            : null,
                        onTap: () => Navigator.pop(sheet, k),
                      ),
                  ]),
                ),
              );
              if (v != null) _appearance((d) => d.colorMode = v);
            },
          ),
          if (d.colorMode == 'gradient' || d.colorMode == '3' || d.colorMode == 'random_Mix' || d.colorMode == '0')
            SettingsTile(
              icon: Icons.auto_awesome_outlined,
              title: '渐变色风格',
              subtitle: const {
                -1: '随机风格',
                0: '粉→蓝',
                1: '金→橙红',
                2: '青→薄荷绿',
                3: '紫→粉',
                4: '天蓝→青',
                5: '玫红→深紫',
                6: '橙→柠檬黄',
                7: '薄荷→蓝绿',
              }[int.tryParse(d.gradientStyle.split(':').first) ?? -1] ?? '随机风格',
              onTap: () async {
                const presets = [
                  (-1, '随机风格'),
                  (0, '粉→蓝'),
                  (1, '金→橙红'),
                  (2, '青→薄荷绿'),
                  (3, '紫→粉'),
                  (4, '天蓝→青'),
                  (5, '玫红→深紫'),
                  (6, '橙→柠檬黄'),
                  (7, '薄荷→蓝绿'),
                ];
                final curPreset = int.tryParse(d.gradientStyle.split(':').first) ?? -1;
                final curWeight = int.tryParse(
                        d.gradientStyle.contains(':w=') ? d.gradientStyle.split(':w=').last : '4') ??
                    4;
                final picked = await showModalBottomSheet<int>(
                  context: context,
                  showDragHandle: true,
                  builder: (sheet) => SafeArea(
                    child: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        for (final (id, label) in presets)
                          ListTile(
                            title: Text(label),
                            trailing: curPreset == id ? Icon(Icons.check, color: AppColors.of(context).accent) : null,
                            onTap: () => Navigator.pop(sheet, id),
                          ),
                      ]),
                    ),
                  ),
                );
                if (picked != null) {
                  final prefix = picked >= 0 && picked <= 7 ? '$picked' : 'none';
                  _appearance((d) => d.gradientStyle = curWeight == 4 ? prefix : '$prefix:w=$curWeight');
                }
              },
            ),
          SettingsTile(
            icon: Icons.block,
            title: l.danmuBlockedWords,
            subtitle: d.blackList.isEmpty ? null : d.blackList.take(3).join('、'),
            onTap: () async {
              await context.push('/settings/danmu/blocked-words');
              final (p2, d2) = await ref.read(playerConfigRepositoryProvider).load();
              if (mounted) {
                setState(() {
                  _p = p2;
                  _d = d2;
                });
              }
            },
          ),
          SliderRow(
              title: l.danmuFontSize,
              value: d.fontSize,
              min: 10,
              max: 40,
              divisions: 30,
              onChanged: (v) => _appearance((d) => d.fontSize = v.roundToDouble())),
          Builder(builder: (context) {
            final curPreset = int.tryParse(d.gradientStyle.split(':').first) ?? -1;
            final curWeight = (int.tryParse(
                        d.gradientStyle.contains(':w=') ? d.gradientStyle.split(':w=').last : '4') ??
                    4)
                .clamp(0, 8);
            const labels = ['最细', '特细', '细', '偏细', '适中', '半粗', '粗', '特粗', '最粗'];
            return SliderRow(
              title: '字体粗细',
              value: curWeight.toDouble(),
              min: 0,
              max: 8,
              divisions: 8,
              label: labels[curWeight],
              onChanged: (v) {
                final w = v.round().clamp(0, 8);
                final prefix = curPreset >= 0 && curPreset <= 7 ? '$curPreset' : 'none';
                _appearance((d) => d.gradientStyle = w == 4 ? prefix : '$prefix:w=$w');
              },
            );
          }),
          SliderRow(
              title: l.danmuLineHeight,
              value: d.lineHeight,
              min: 1,
              max: 3,
              divisions: 20,
              label: fixed(d.lineHeight, 1),
              onChanged: (v) => _appearance((d) => d.lineHeight = double.parse(v.toStringAsFixed(1)))),
          SliderRow(
              title: l.danmuOpacity,
              value: d.opacity,
              min: 0.1,
              max: 1,
              divisions: 18,
              label: fixed(d.opacity, 2),
              onChanged: (v) => _appearance((d) => d.opacity = double.parse(v.toStringAsFixed(2)))),
          SliderRow(
              title: l.danmuArea,
              value: d.area,
              min: 0.1,
              max: 1,
              divisions: 9,
              label: fixed(d.area, 1),
              onChanged: (v) => _appearance((d) => d.area = double.parse(v.toStringAsFixed(1)))),
          SliderRow(
              title: l.danmuScrollSpeed,
              value: d.scrollSpeed,
              min: 0.3,
              max: 2,
              divisions: 17,
              label: fixed(d.scrollSpeed, 1),
              onChanged: (v) => _appearance((d) => d.scrollSpeed = double.parse(v.toStringAsFixed(1)))),
          SliderRow(
              title: l.danmuStroke,
              value: d.strokeWidth,
              min: 0,
              max: 4,
              divisions: 8,
              label: fixed(d.strokeWidth, 1),
              onChanged: (v) => _appearance((d) => d.strokeWidth = double.parse(v.toStringAsFixed(1)))),
          SliderRow(
            title: l.danmuDelay,
            value: d.delaySeconds,
            min: -30,
            max: 30,
            divisions: 120,
            label: '${fixed(d.delaySeconds, 1)} ${l.secondsShort}',
            onChanged: (v) => _appearance((d) => d.delaySeconds = double.parse(v.toStringAsFixed(1))),
          ),
        ])),
      ]),
    );
  }
}

/// −/+ stepper with the value between (OBSERVED on 端口 and the player's 默认倍速 / 快进快退秒数 / 长按倍速).
class ValueStepper extends StatelessWidget {
  const ValueStepper({super.key, required this.value, required this.onMinus, required this.onPlus});
  final String value;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    Widget round(IconData icon, VoidCallback? onTap) => InkResponse(
          onTap: onTap == null
              ? null
              : () {
                  AppHaptics.selection();
                  onTap();
                },
          radius: 20,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.of(context).accent.withValues(alpha: onTap == null ? 0.08 : 0.2)),
            child: Icon(icon, size: 18, color: AppColors.of(context).accent.withValues(alpha: onTap == null ? 0.4 : 1)),
          ),
        );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      round(Icons.remove, onMinus),
      SizedBox(
          width: 50,
          child: Text(value,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.label))),
      round(Icons.add, onPlus),
    ]);
  }
}

/// `/settings/danmu/blocked-words` (OBSERVED strings 屏蔽词管理, 暂无屏蔽词，命中屏蔽词的弹幕将被过滤).
class DanmuBlockedWordsScreen extends ConsumerStatefulWidget {
  const DanmuBlockedWordsScreen({super.key});
  @override
  ConsumerState<DanmuBlockedWordsScreen> createState() => _DanmuBlockedWordsScreenState();
}

class _DanmuBlockedWordsScreenState extends ConsumerState<DanmuBlockedWordsScreen> {
  PlaybackConfig? _p;
  DanmakuConfig? _d;

  @override
  void initState() {
    super.initState();
    ref.read(playerConfigRepositoryProvider).load().then((v) {
      if (!mounted) return;
      setState(() {
        _p = v.$1;
        _d = v.$2;
      });
    });
  }

  Future<void> _set(List<String> words) async {
    setState(() => _d!.blackList = words);
    await ref.read(playerConfigRepositoryProvider).save(_p!, _d!);
  }

  Future<void> _add() async {
    final l = context.l10n;
    final controller = TextEditingController();
    final word = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l.danmuBlockedWordAdd),
        content: TextField(controller: controller, autofocus: true, onSubmitted: (v) => Navigator.pop(c, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(l.cancel)),
          TextButton(onPressed: () => Navigator.pop(c, controller.text), child: Text(l.ok)),
        ],
      ),
    );
    controller.dispose();
    final w = word?.trim() ?? '';
    if (w.isEmpty || _d!.blackList.contains(w)) return;
    await _set([..._d!.blackList, w]);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final d = _d;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.danmuBlockedWordsTitle),
        actions: [
          IconButton(tooltip: l.danmuBlockedWordAdd, icon: const Icon(Icons.add), onPressed: d == null ? null : _add)
        ],
      ),
      body: d == null
          ? const Center(child: CircularProgressIndicator())
          : d.blackList.isEmpty
              ? EmptyState(icon: Icons.block, title: l.noData, subtitle: l.danmuBlockedWordsEmpty)
              : ListView(children: [
                  SettingsSection(children: [
                    for (final w in d.blackList)
                      SettingsTile(
                        title: w,
                        trailing: IconButton(
                          icon: Icon(Icons.remove_circle_outline, color: AppColors.of(context).secondaryLabel),
                          onPressed: () => _set([...d.blackList]..remove(w)),
                        ),
                      ),
                  ]),
                ]),
    );
  }
}
