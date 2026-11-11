import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/app_lock.dart';
import '../app/app_preferences.dart';
import '../app/theme.dart';
import '../app/ui_hooks.dart';
import '../l10n/l10n.dart';

// The original's three lock dialogs (OBSERVED 2026-11-09, docs/ui-ref/original/orig_lock_*.png) share one keypad: 2×2
// colour tiles of ~90 dp with bold digits, a grey backspace tile to the right, and above them either the hint
// 点击色块输入密码 or one small numbered dot per digit typed. An error line (danger colour) goes above that.

/// OBSERVED tile colours (the iOS system red, blue, green and yellow). Digits are white on red and blue, near black on
/// green and yellow.
const _lockKeys = [
  (digit: '1', color: Color(0xFFFF3B30), ink: Color(0xFFFFFFFF)),
  (digit: '2', color: Color(0xFF007AFF), ink: Color(0xFFFFFFFF)),
  (digit: '3', color: Color(0xFF34C759), ink: Color(0xFF071B0C)),
  (digit: '4', color: Color(0xFFFFCC00), ink: Color(0xFF1F1900)),
];

const _tile = 90.0;
const _gap = 12.0;
const _backspace = 48.0;
const _keypadWidth = _tile * 2 + _gap * 2 + _backspace;

class ColorKeypad extends StatelessWidget {
  const ColorKeypad({super.key, required this.code, required this.onChanged, this.error});

  /// The digits typed so far.
  final String code;
  final ValueChanged<String> onChanged;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    Widget key(int i) {
      final k = _lockKeys[i];
      return Material(
        color: k.color,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onChanged(code + k.digit),
          child: SizedBox.square(
            dimension: _tile,
            child:
                Center(child: Text(k.digit, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: k.ink))),
          ),
        ),
      );
    }

    Widget dot(String digit) {
      final k = _lockKeys.firstWhere((k) => k.digit == digit);
      return Container(
        width: 22,
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: k.color, shape: BoxShape.circle),
        child: Text(digit, style: TextStyle(fontSize: 12, height: 1, fontWeight: FontWeight.w700, color: k.ink)),
      );
    }

    return SizedBox(
      width: _keypadWidth,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(error!,
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: AppColors.danger)),
          ),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 24),
          child: Center(
            child: code.isEmpty
                ? Text(l.lockTapHint,
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: c.secondaryLabel))
                : Wrap(
                    spacing: 10,
                    runSpacing: 6,
                    alignment: WrapAlignment.center,
                    children: [for (final d in code.split('')) dot(d)]),
          ),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Column(children: [
            Row(children: [key(0), const SizedBox(width: _gap), key(1)]),
            const SizedBox(height: _gap),
            Row(children: [key(2), const SizedBox(width: _gap), key(3)]),
          ]),
          const SizedBox(width: _gap),
          Material(
            color: Color.alphaBlend(c.label.withValues(alpha: 0.07), c.card),
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: code.isEmpty ? null : () => onChanged(code.substring(0, code.length - 1)),
              child: SizedBox.square(
                dimension: _backspace,
                child: Icon(Icons.backspace, size: 20, color: c.label, semanticLabel: l.lockBackspace),
              ),
            ),
          ),
        ]),
      ]),
    );
  }
}

/// 解锁 / 解锁订阅: asks for the code when one is set (验证锁密码), then opens the lock for 订阅管理 and the home page.
Future<void> unlockSubscriptions(BuildContext context, WidgetRef ref) async {
  final hash = ref.read(appPreferencesProvider).lockHash;
  if (lockNeedsCode(hash)) {
    final ok = await showDialog<bool>(context: context, builder: (c) => _VerifyLockDialog(hash: hash!));
    if (ok != true || !context.mounted) return;
  }
  ref.read(subscriptionsUnlockedProvider.notifier).unlock();
}

/// OBSERVED 验证锁密码: no buttons and no error. It closes by itself as soon as the digits typed match, and the barrier or
/// back closes it without unlocking.
class _VerifyLockDialog extends StatefulWidget {
  const _VerifyLockDialog({required this.hash});
  final String hash;

  @override
  State<_VerifyLockDialog> createState() => _VerifyLockDialogState();
}

class _VerifyLockDialogState extends State<_VerifyLockDialog> {
  String _code = '';

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(context.l10n.lockVerifyTitle),
        content: ColorKeypad(
          code: _code,
          onChanged: (v) {
            if (lockCodeMatches(widget.hash, v)) {
              Navigator.pop(context, true);
            } else {
              setState(() => _code = v);
            }
          },
        ),
      );
}

/// Before 上锁 while no password exists (未设置), from 编辑订阅 and 添加订阅: OBSERVED 首次上锁 with 取消 / 不设置 / 确认.
/// 确认 keeps the digits typed as the password (no second entry), 不设置 the empty one. Returns whether to lock.
Future<bool> confirmFirstLock(BuildContext context, WidgetRef ref) async {
  if (lockStateOf(ref.read(appPreferencesProvider).lockHash) != LockPasswordState.notSet) return true;
  final l = context.l10n;
  final code = await showDialog<String>(context: context, builder: (c) => const _FirstLockDialog());
  if (code == null || !context.mounted) return false;
  await ref.read(appPreferencesProvider.notifier).setLockCode(code);
  if (code.isEmpty) showToast(l.lockSetEmpty); // INFERRED: the original has this string; where it shows was not seen
  return true;
}

class _FirstLockDialog extends StatefulWidget {
  const _FirstLockDialog();

  @override
  State<_FirstLockDialog> createState() => _FirstLockDialogState();
}

class _FirstLockDialogState extends State<_FirstLockDialog> {
  String _code = '';
  String? _error;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    return AlertDialog(
      title: Text(l.lockFirstTitle),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.lockFirstBody, style: TextStyle(fontSize: 14, height: 1.45, color: c.subtitle)),
        const SizedBox(height: 14),
        Center(child: ColorKeypad(code: _code, error: _error, onChanged: (v) => setState(() => _code = v))),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        TextButton(onPressed: () => Navigator.pop(context, ''), child: Text(l.lockSkip)),
        FilledButton(
          // INFERRED: 确认 with nothing typed is refused like 下一步 in 设置 → 锁密码 (不设置 is the way to an empty password)
          onPressed: () => _code.isEmpty ? setState(() => _error = l.lockTooShort) : Navigator.pop(context, _code),
          child: Text(l.lockConfirm),
        ),
      ],
    );
  }
}

/// 设置 → 锁密码.
Future<void> showLockPasswordDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (c) => const _LockPasswordDialog());

enum _Step { old, fresh, again }

/// OBSERVED: a state line (尚未设置锁密码 / 当前已设置锁密码) and a step line. With a password set it starts at 验证旧密码
/// (取消 / 清除 / 下一步; a wrong code shows 旧密码错误 and empties the input, and 清除 needs the right code too), then
/// 输入新密码 (取消 / 下一步; nothing typed shows 请至少输入一位), then 再次输入确认 (取消 / 确认; a different code goes back
/// to 输入新密码 with 两次输入不一致，请重试). With the empty password there is nothing to verify, so it starts at 输入新密码
/// and keeps 清除 there (INFERRED).
class _LockPasswordDialog extends ConsumerStatefulWidget {
  const _LockPasswordDialog();

  @override
  ConsumerState<_LockPasswordDialog> createState() => _LockPasswordDialogState();
}

class _LockPasswordDialogState extends ConsumerState<_LockPasswordDialog> {
  late final String? _hash = ref.read(appPreferencesProvider).lockHash;
  late final LockPasswordState _state = lockStateOf(_hash);
  late _Step _step = _state == LockPasswordState.set ? _Step.old : _Step.fresh;
  String _code = '';
  String _first = '';
  String? _error;

  void _go(_Step step, {String? error}) => setState(() {
        _step = step;
        _code = '';
        _error = error;
      });

  Future<void> _finish(String? code, String message) async {
    await ref.read(appPreferencesProvider.notifier).setLockCode(code);
    if (mounted) Navigator.pop(context);
    showToast(message);
  }

  void _clear() {
    final l = context.l10n;
    if (_state == LockPasswordState.set && !lockCodeMatches(_hash, _code)) return _go(_Step.old, error: l.lockWrongOld);
    _finish(null, l.lockCleared);
  }

  void _next() {
    final l = context.l10n;
    switch (_step) {
      case _Step.old:
        if (lockCodeMatches(_hash, _code)) {
          _go(_Step.fresh);
        } else {
          _go(_Step.old, error: l.lockWrongOld);
        }
      case _Step.fresh:
        if (_code.isEmpty) return setState(() => _error = l.lockTooShort);
        _first = _code;
        _go(_Step.again);
      case _Step.again:
        if (_code == _first) {
          _finish(_code, l.lockUpdated);
        } else {
          _go(_Step.fresh, error: l.lockMismatch);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    final stateLine = switch (_state) {
      LockPasswordState.notSet => l.lockStateNotSet,
      LockPasswordState.empty => l.lockStateEmpty,
      LockPasswordState.set => l.lockStateSet,
    };
    final stepLine = switch (_step) {
      _Step.old => l.lockStepOld,
      _Step.fresh => l.lockStepNew,
      _Step.again => l.lockStepConfirm,
    };
    final canClear = _step == _Step.old || (_state == LockPasswordState.empty && _step == _Step.fresh);
    return AlertDialog(
      title: Text(l.lockPassword),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(stateLine, style: TextStyle(fontSize: 13.5, color: c.subtitle)),
        const SizedBox(height: 6),
        Text(stepLine, style: TextStyle(fontSize: 15.5, color: c.label)),
        const SizedBox(height: 14),
        Center(child: ColorKeypad(code: _code, error: _error, onChanged: (v) => setState(() => _code = v))),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        if (canClear) TextButton(onPressed: _clear, child: Text(l.lockClear)),
        FilledButton(onPressed: _next, child: Text(_step == _Step.again ? l.lockConfirm : l.lockNext)),
      ],
    );
  }
}

/// Subtitle of the 锁密码 row.
String lockStateLabel(AppLocalizations l, String? hash) => switch (lockStateOf(hash)) {
      LockPasswordState.notSet => l.lockNotSet,
      LockPasswordState.empty => l.lockEmpty,
      LockPasswordState.set => l.lockSet,
    };
