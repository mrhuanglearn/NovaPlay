import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/theme.dart';
import '../app/ui_hooks.dart';
import '../features/catpaw/catpaw_debug.dart';
import '../features/catpaw/catpaw_protocol.dart';
import '../l10n/l10n.dart';
import 'form_widgets.dart';
import 'widgets.dart';

// Layout OBSERVED on the original (docs/ui-ref/original/orig_debug_*.png); see catpaw_debug.dart. The original's buttons
// on this page have light text (#E2E2E9) rather than the dark navy used elsewhere. Not carried over: the switch
// 开启局域网代理(Dart 反向代理), since this project has no Dart reverse proxy.

const _running = Color(0xFF4CAF50); // OBSERVED status dot
const _mono = TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.4);

/// `/debug` (设置 → 开发者 → catpaw 调试).
class CatpawDebugScreen extends ConsumerStatefulWidget {
  const CatpawDebugScreen({super.key});
  @override
  ConsumerState<CatpawDebugScreen> createState() => _CatpawDebugScreenState();
}

class _CatpawDebugScreenState extends ConsumerState<CatpawDebugScreen> {
  final _dartPort = TextEditingController();
  final _url = TextEditingController();
  final _name = TextEditingController();
  final _port = TextEditingController();
  final _serviceUrl = TextEditingController();
  final _serviceName = TextEditingController();
  final _servicePort = TextEditingController();
  bool _services = false;
  bool _force = false;
  bool _netLog = true;
  bool _serviceLog = true;

  @override
  void dispose() {
    for (final c in [_dartPort, _url, _name, _port, _serviceUrl, _serviceName, _servicePort]) {
      c.dispose();
    }
    super.dispose();
  }

  int? _int(TextEditingController c) => int.tryParse(c.text.trim());

  CatpawDebugController get _ctrl => ref.read(catpawDebugProvider.notifier);

  Future<void> _copy(String text, String toast) async {
    await Clipboard.setData(ClipboardData(text: text));
    showToast(toast);
  }

  Future<void> _pickLocalScript() async {
    final f = await FilePicker.pickFile(type: FileType.any);
    if (f == null) return;
    await _ctrl.installLocalService(
      bytes: await f.readAsBytes(),
      fileName: f.name,
      name: _serviceName.text,
      defaultPort: _int(_servicePort),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = ref.watch(catpawDebugProvider);
    final bottom = 32 + MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      appBar: AppBar(title: Text(l.debugTitle, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w400))),
      body: state.node == DebugNodeState.running
          ? ListView(padding: EdgeInsets.only(bottom: bottom), children: [
              _statusRow(context),
              _lastResultCard(context, state),
              _logCard(context, state),
              _Tabs(services: _services, onChanged: (v) => setState(() => _services = v)),
              if (_services) ..._servicesTab(context, state) else ..._catpawTab(context, state),
            ])
          : ListView(padding: EdgeInsets.only(top: 26, bottom: bottom), children: [_startCard(context, state)]),
    );
  }

  Widget _startCard(BuildContext context, CatpawDebugState state) {
    final l = context.l10n;
    final c = AppColors.of(context);
    final starting = state.node == DebugNodeState.starting;
    return _Card(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
                color: AppColors.of(context).accent.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(10)),
            child: Icon(Icons.play_circle_filled, color: AppColors.of(context).accent, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.debugStartTitle, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.label)),
              const SizedBox(height: 4),
              Text(l.debugStartSub, style: TextStyle(fontSize: 13, color: c.subtitle)),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        LabeledField(
          controller: _dartPort,
          label: l.debugDartPort,
          keyboardType: TextInputType.number,
          padding: const EdgeInsets.symmetric(vertical: 8),
        ),
        const SizedBox(height: 12),
        _WideButton(
          icon: starting ? null : Icons.power_settings_new,
          label: starting ? l.debugNodeStarting : l.debugStartNode,
          busy: starting,
          onPressed: starting ? null : () => _ctrl.startNode(dartPort: _int(_dartPort)),
        ),
      ]),
    );
  }

  Widget _statusRow(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
        child: Row(children: [
          Container(width: 8, height: 8, decoration: const BoxDecoration(color: _running, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Text(context.l10n.debugNodeRunning,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.of(context).label)),
        ]),
      );

  Widget _lastResultCard(BuildContext context, CatpawDebugState state) {
    final l = context.l10n;
    final c = AppColors.of(context);
    final result = state.lastResult;
    return _Card(
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
      child: Row(children: [
        Icon(Icons.history, size: 20, color: c.subtitle),
        const SizedBox(width: 8),
        Text(l.debugLastResult, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: c.label)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(result ?? '-',
              maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: c.subtitle)),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: l.debugCopyLast,
          icon: Icon(Icons.copy_outlined, size: 20, color: c.label),
          onPressed: result == null ? null : () => _copy(result, l.debugCopiedLast),
        ),
      ]),
    );
  }

  Widget _logCard(BuildContext context, CatpawDebugState state) {
    final l = context.l10n;
    final c = AppColors.of(context);
    return _Card(
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 14),
      child: Column(children: [
        Row(children: [
          Icon(Icons.terminal, size: 20, color: c.subtitle),
          const SizedBox(width: 8),
          Expanded(
              child: Text(l.debugLog, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: c.label))),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: l.debugCopyAllLogs,
            icon: Icon(Icons.copy_all_outlined, size: 20, color: c.label),
            onPressed: state.log.isEmpty ? null : () => _copy(_ctrl.logText, l.copied),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: l.debugClearLogs,
            icon: Icon(Icons.delete_outline, size: 20, color: c.label),
            onPressed: state.log.isEmpty
                ? null
                : () {
                    _ctrl.clearLog();
                    showToast(l.debugLogsCleared);
                  },
          ),
        ]),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(right: 10),
          child: Container(
            height: 180,
            width: double.infinity,
            decoration: BoxDecoration(color: c.cardHigh, borderRadius: BorderRadius.circular(8)),
            child: state.log.isEmpty
                ? Center(child: Text(l.debugNoLogs, style: TextStyle(fontSize: 13, color: c.secondaryLabel)))
                : LayoutBuilder(
                    // Starts at the top like the original; once longer than the box, the newest line stays in view.
                    builder: (context, box) => SingleChildScrollView(
                      reverse: true,
                      padding: const EdgeInsets.all(10),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: box.maxHeight - 20, minWidth: double.infinity),
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: SelectableText(_ctrl.logText, style: _mono.copyWith(color: c.label)),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ]),
    );
  }

  List<Widget> _catpawTab(BuildContext context, CatpawDebugState state) {
    final l = context.l10n;
    return [
      SettingsSection(title: l.debugLoadInstance, dividers: false, children: [
        LabeledField(controller: _url, label: 'catpaw index.js URL', keyboardType: TextInputType.url),
        LabeledField(controller: _name, label: l.debugInstanceName),
        LabeledField(controller: _port, label: l.debugPort, keyboardType: TextInputType.number),
        SwitchRow(title: l.debugForceRestart, value: _force, onChanged: (v) => setState(() => _force = v)),
        SwitchRow(title: l.debugNetAudit, value: _netLog, onChanged: (v) => setState(() => _netLog = v)),
        SwitchRow(title: l.debugServiceLog, value: _serviceLog, onChanged: (v) => setState(() => _serviceLog = v)),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
          child: _WideButton(
            label: l.debugLoadButton,
            busy: state.busy,
            onPressed: state.busy
                ? null
                : () => _ctrl.loadInstance(
                      url: _url.text,
                      name: _name.text,
                      port: _int(_port),
                      force: _force,
                      netLog: _netLog,
                      serviceLog: _serviceLog,
                    ),
          ),
        ),
      ]),
      _ListSection(
        title: l.debugRunningInstances,
        empty: l.debugNoInstance,
        items: state.instances,
        actions: (i) => [
          if (i.running && i.port != null)
            IconButton(
                tooltip: l.debugTest,
                icon: const Icon(Icons.science_outlined, size: 20),
                onPressed: () => _ctrl.testInstance(i)),
          IconButton(
            tooltip: l.debugStop,
            icon: Icon(Icons.stop_circle_outlined, size: 20, color: AppColors.dangerText(context)),
            onPressed: () => _ctrl.stopInstance(i.name),
          ),
        ],
      ),
    ];
  }

  List<Widget> _servicesTab(BuildContext context, CatpawDebugState state) {
    final l = context.l10n;
    return [
      SettingsSection(title: l.debugInstallService, dividers: false, children: [
        LabeledField(controller: _serviceUrl, label: l.debugServiceUrl, keyboardType: TextInputType.url),
        LabeledField(controller: _serviceName, label: l.debugServiceName),
        LabeledField(controller: _servicePort, label: l.debugDefaultPort, keyboardType: TextInputType.number),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
          child: _WideButton(
            label: l.debugInstallService,
            busy: state.busy,
            onPressed: state.busy
                ? null
                : () => _ctrl.installService(
                    url: _serviceUrl.text, name: _serviceName.text, defaultPort: _int(_servicePort)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(40),
              foregroundColor: AppColors.of(context).label,
              side: BorderSide(color: AppColors.of(context).secondaryLabel),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: state.busy ? null : _pickLocalScript,
            child: Text(l.debugLoadLocalScript),
          ),
        ),
      ]),
      _ListSection(
        title: l.debugRegisteredServices,
        empty: l.debugNoService,
        items: state.services,
        actions: (s) => s.running
            ? [
                IconButton(
                  tooltip: l.debugStopService,
                  icon: Icon(Icons.stop_circle_outlined, size: 20, color: AppColors.dangerText(context)),
                  onPressed: () => _ctrl.stopService(s.name),
                ),
              ]
            : [
                IconButton(
                  tooltip: l.debugStartService,
                  icon: Icon(Icons.play_circle_outline, size: 20, color: AppColors.of(context).accent),
                  onPressed: () => _ctrl.startService(s.name),
                ),
                IconButton(
                  tooltip: l.debugUninstallService,
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () => _ctrl.uninstallService(s.name),
                ),
              ],
      ),
    ];
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, required this.padding});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        padding: padding,
        decoration: BoxDecoration(color: AppColors.of(context).card, borderRadius: BorderRadius.circular(14)),
        child: child,
      );
}

/// OBSERVED: full-width accent buttons with light text on this page.
class _WideButton extends StatelessWidget {
  const _WideButton({required this.label, required this.onPressed, this.icon, this.busy = false});
  final String label;
  final IconData? icon;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return FilledButton(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(40),
        foregroundColor: c.label,
        disabledBackgroundColor: AppColors.of(context).accent.withValues(alpha: 0.5),
        disabledForegroundColor: c.label.withValues(alpha: 0.8),
      ),
      onPressed: onPressed,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (busy)
          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: c.label))
        else if (icon != null)
          Icon(icon, size: 20),
        if (busy || icon != null) const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontSize: 15)),
      ]),
    );
  }
}

/// OBSERVED catpaw / 通用服务 switch: the chosen half on a card-coloured chip, bold.
class _Tabs extends StatelessWidget {
  const _Tabs({required this.services, required this.onChanged});
  final bool services;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    Widget tab(String label, bool selected, bool value) => Expanded(
          child: Material(
            color: selected ? c.card : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                // The other tab's fields replace these; a focused one would hand its focus (and keyboard) over.
                FocusScope.of(context).unfocus();
                onChanged(value);
              },
              child: SizedBox(
                height: 32,
                child: Center(
                  child: Text(label,
                      style: TextStyle(
                          fontSize: 15, fontWeight: selected ? FontWeight.w600 : FontWeight.w400, color: c.label)),
                ),
              ),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 0),
      child: Row(children: [
        tab('catpaw', !services, false),
        const SizedBox(width: 8),
        tab(context.l10n.debugTabServices, services, true),
      ]),
    );
  }
}

/// 运行实例 / 已注册服务: a dot, the name, "running :port" or "stopped", the data folder, and the row's buttons.
class _ListSection extends StatelessWidget {
  const _ListSection({required this.title, required this.empty, required this.items, required this.actions});
  final String title;
  final String empty;
  final List<CatpawInstance> items;
  final List<Widget> Function(CatpawInstance) actions;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final small = TextStyle(fontSize: 12, color: c.subtitle, height: 1.35);
    if (items.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SettingsSection(title: title, dividers: false, children: const []),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Center(child: Text(empty, style: TextStyle(fontSize: 13.5, color: c.subtitle))),
        ),
      ]);
    }
    return SettingsSection(title: title, children: [
      for (final i in items)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
          child: Row(children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: i.running ? _running : c.secondaryLabel, shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(i.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.label)),
                const SizedBox(height: 3),
                Text(i.running ? 'running :${i.port ?? '-'}' : 'stopped', style: small),
                if (i.dataDir != null) Text(i.dataDir!, style: small),
              ]),
            ),
            ...actions(i),
          ]),
        ),
    ]);
  }
}
