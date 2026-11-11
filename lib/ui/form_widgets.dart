import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../core/haptics.dart';
import 'widgets.dart';

/// Rows used inside a [SettingsSection]. They draw no card of their own.
class SwitchRow extends StatelessWidget {
  const SwitchRow(
      {super.key, required this.title, required this.value, required this.onChanged, this.subtitle, this.icon});
  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => SettingsTile(
        icon: icon,
        title: title,
        subtitle: subtitle,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        trailing: Switch(
          value: value,
          onChanged: onChanged == null
              ? null
              : (v) {
                  AppHaptics.light();
                  onChanged!(v);
                },
        ),
      );
}

class SliderRow extends StatelessWidget {
  const SliderRow({
    super.key,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.suffix = '',
    this.label,
  });

  /// Shown instead of the default value text (e.g. "1.00" with fixed decimals).
  final String? label;
  final String title;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String suffix;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(title, style: TextStyle(fontSize: 14.5, color: c.label))),
          Text(label ?? '${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 2)}$suffix',
              style: TextStyle(fontSize: 11.5, color: c.secondaryLabel)),
        ]),
        Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions, onChanged: onChanged),
      ]),
    );
  }
}

class ChoiceRow<T> extends StatelessWidget {
  const ChoiceRow(
      {super.key,
      required this.title,
      required this.value,
      required this.options,
      required this.onChanged,
      this.subtitle});
  final String title;
  final String? subtitle;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => SettingsTile(
        title: title,
        subtitle: subtitle,
        trailing: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: options.containsKey(value) ? value : options.keys.first,
            borderRadius: BorderRadius.circular(10),
            style: TextStyle(fontSize: 14, color: AppColors.of(context).secondaryLabel),
            items: [for (final e in options.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      );
}

/// Section label for screens that list rows without a card (prefer [SettingsSection]).
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 9),
        child: Text(text,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.of(context).subtitle)),
      );
}

class TextRow extends StatelessWidget {
  const TextRow(
      {super.key,
      required this.controller,
      required this.label,
      this.hint,
      this.obscure = false,
      this.keyboard,
      this.maxLines = 1});
  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool obscure;
  final TextInputType? keyboard;
  final int maxLines;

  @override
  Widget build(BuildContext context) => LabeledField(
      controller: controller,
      label: label,
      hint: hint,
      obscure: obscure,
      keyboardType: keyboard,
      maxLines: maxLines,
      paste: !obscure);
}

/// Text field that reports its value when submitted or when it loses focus (not on every keystroke), for settings
/// that are written to disk and synced.
class CommitTextRow extends StatelessWidget {
  const CommitTextRow({super.key, required this.controller, required this.label, required this.onCommit, this.hint});
  final TextEditingController controller;
  final String label;
  final String? hint;
  final ValueChanged<String> onCommit;

  @override
  Widget build(BuildContext context) => Focus(
        onFocusChange: (focused) {
          if (!focused) onCommit(controller.text);
        },
        child: LabeledField(controller: controller, label: label, hint: hint, onSubmitted: onCommit),
      );
}
