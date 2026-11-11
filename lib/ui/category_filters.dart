import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../models/vod.dart';

/// A category's filters laid out inline, one row per filter, as the original shows them above the posters.
///
/// OBSERVED (2026-11-09, mock site with 年份 / 地区 / 排序; Waydroid at 180 dpi, so 1 dp = 1.125 px): rows ≈ 38.7 dp
/// apart; the filter name in bold grey 16 dp from the left; the values as 12 dp text about 6 dp apart, the selected one
/// on a dark blue rounded box (≈ 33 dp high, radius 9) in bold accent.
/// Before anything is picked the filter's `init` value is selected (全部 when it is empty). Picking a value reloads the
/// list; the rows scroll away with the posters.
class CategoryFilterBar extends StatelessWidget {
  const CategoryFilterBar({super.key, required this.filters, required this.chosen, required this.onChanged});
  final List<VodFilter> filters;

  /// The values picked so far (key → value). A missing key shows the filter's `init` value as selected.
  final Map<String, String> chosen;
  final void Function(VodFilter filter, String value) onChanged;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final accent = c.accent;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final selectedFill = dark
        ? Color.alphaBlend(accent.withValues(alpha: 0.3), Color.alphaBlend(c.label.withValues(alpha: 0.12), c.page))
        : accent.withValues(alpha: 0.14);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 6),
      child: Column(children: [
        for (final f in filters)
          SizedBox(
            height: 38.7,
            child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(left: 16, right: 12),
                children: [
                  Center(
                    child:
                        Text(f.name, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c.subtitle)),
                  ),
                  const SizedBox(width: 10.7),
                  for (final v in f.values)
                    _FilterValue(
                      label: v.key,
                      selected: (chosen[f.key] ?? f.init) == v.value,
                      fill: selectedFill,
                      onTap: () => onChanged(f, v.value),
                    ),
                ]),
          ),
      ]),
    );
  }
}

class _FilterValue extends StatelessWidget {
  const _FilterValue({required this.label, required this.selected, required this.fill, required this.onTap});
  final String label;
  final bool selected;
  final Color fill;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2.85, bottom: 2.85, right: 6),
      child: Material(
        color: selected ? fill : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
                  color: selected ? c.accent : c.subtitle,
                )),
          ),
        ),
      ),
    );
  }
}
