import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../app/theme.dart';
import '../core/haptics.dart';
import '../l10n/l10n.dart';
import '../models/vod.dart';
import 'load_error.dart';

/// Poster grid used by home, search, favorites and history.
class VodGrid extends StatelessWidget {
  const VodGrid(
      {super.key,
      required this.items,
      this.onNearEnd,
      this.controller,
      this.bottomInset = 0,
      this.header,
      this.footer});
  final List<VodItem> items;
  final VoidCallback? onNearEnd;
  final ScrollController? controller;

  /// Extra bottom padding, for grids that scroll under the floating navigation bar.
  final double bottomInset;

  /// Scrolls with the posters, above them (the home page's filter rows) / below them (a loading indicator).
  final Widget? header;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    // changelog 1.1.4: lists adapt to tablets / desktops with multi-column grids
    final columns = (width / 130).floor().clamp(2, 10);
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (onNearEnd != null && n.metrics.pixels >= n.metrics.maxScrollExtent - 300) onNearEnd!();
        return false;
      },
      child: CustomScrollView(controller: controller, slivers: [
        if (header != null) SliverToBoxAdapter(child: header),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(11, 12, 11, footer == null ? 12 + bottomInset : 0),
          sliver: SliverGrid(
            gridDelegate: _posterGrid(columns),
            delegate: SliverChildBuilderDelegate((context, i) => VodCard(item: items[i]), childCount: items.length),
          ),
        ),
        if (footer != null)
          SliverPadding(padding: EdgeInsets.only(bottom: 12 + bottomInset), sliver: SliverToBoxAdapter(child: footer)),
      ]),
    );
  }
}

/// OBSERVED: three columns on a phone, 140×199 posters with an 11 px gutter.
SliverGridDelegate _posterGrid(int columns) => SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      childAspectRatio: 0.6,
      crossAxisSpacing: 11,
      mainAxisSpacing: 14,
    );

/// Opens the detail page of [item].
void openVod(BuildContext context, VodItem item) => _openVod(context, item);

/// The poster of [item], or the film-icon placeholder.
Widget vodPoster(VodItem item) => _poster(item);

void _openVod(BuildContext context, VodItem item) {
  AppHaptics.selection();
  final q =
      Uri(path: '/video/detail', queryParameters: {'id': item.id, if (item.siteKey != null) 'site': item.siteKey!});
  context.push(q.toString());
}

const _defaultPosterUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

final _catVodHeaderTag = RegExp(
  r'@(Referer|User-Agent|Cookie|Origin|Authorization|Accept)=([^@]*)',
  caseSensitive: false,
);

/// Parses CatVod poster URLs that may carry `@Referer=...` / `@User-Agent=...` suffixes and adds anti-hotlink
/// headers required by hosts like `*.doubanio.com`.
({String url, Map<String, String> headers}) parsePosterRequest(String raw) {
  final headers = <String, String>{};
  var clean = raw.trim();
  for (final m in _catVodHeaderTag.allMatches(clean)) {
    final k = m.group(1)!;
    final v = m.group(2)!.trim();
    if (v.isEmpty) continue;
    final canonical = switch (k.toLowerCase()) {
      'referer' => 'Referer',
      'user-agent' => 'User-Agent',
      'cookie' => 'Cookie',
      'origin' => 'Origin',
      'authorization' => 'Authorization',
      'accept' => 'Accept',
      _ => k,
    };
    headers[canonical] = v;
  }
  final firstTag = _catVodHeaderTag.firstMatch(clean);
  if (firstTag != null) {
    clean = clean.substring(0, firstTag.start).trim();
  }
  final uri = Uri.tryParse(clean);
  final host = uri?.host.toLowerCase() ?? '';
  if ((host.endsWith('doubanio.com') || host.endsWith('douban.com')) && !headers.containsKey('Referer')) {
    headers['Referer'] = 'https://movie.douban.com/';
  }
  headers.putIfAbsent('User-Agent', () => _defaultPosterUserAgent);
  return (url: clean, headers: headers);
}

Widget _poster(VodItem item) {
  final raw = item.pic;
  if (raw == null || raw.trim().isEmpty) return const _PosterFallback();
  final req = parsePosterRequest(raw);
  if (req.url.isEmpty) return const _PosterFallback();
  return Image.network(
    req.url,
    headers: req.headers,
    fit: BoxFit.cover,
    errorBuilder: (_, __, ___) => const _PosterFallback(),
  );
}

/// OBSERVED poster card: radius 12, the remark in a small dark chip at the bottom left, the title centred below.
class VodCard extends StatelessWidget {
  const VodCard({super.key, required this.item});
  final VodItem item;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _openVod(context, item),
      child: Column(children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(fit: StackFit.expand, children: [
              _poster(item),
              if ((item.remarks ?? '').isNotEmpty)
                Positioned(
                  left: 7,
                  bottom: 7,
                  right: 7,
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(4)),
                      child: Text(item.remarks!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 9.5)),
                    ),
                  ),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 7),
        Text(item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: c.label)),
        const SizedBox(height: 2),
      ]),
    );
  }
}

/// The list form of [VodGrid] (the original's 切换布局).
class VodList extends StatelessWidget {
  const VodList({super.key, required this.items, this.onNearEnd, this.bottomInset = 0, this.header, this.footer});
  final List<VodItem> items;
  final VoidCallback? onNearEnd;
  final double bottomInset;
  final Widget? header;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (onNearEnd != null && n.metrics.pixels >= n.metrics.maxScrollExtent - 300) onNearEnd!();
        return false;
      },
      child: ListView.builder(
        padding: EdgeInsets.fromLTRB(0, 0, 0, 12 + bottomInset),
        itemCount: items.length + 2,
        itemBuilder: (context, k) {
          if (k == 0) return Column(children: [if (header != null) header!, const SizedBox(height: 8)]);
          if (k == items.length + 1) return footer ?? const SizedBox.shrink();
          final item = items[k - 1];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _openVod(context, item),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(width: 64, height: 90, child: _poster(item))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(item.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 15.5, color: c.label)),
                      if ((item.remarks ?? '').isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(item.remarks!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: c.secondaryLabel)),
                      ],
                    ]),
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PosterFallback extends StatelessWidget {
  const _PosterFallback();
  @override
  Widget build(BuildContext context) => ColoredBox(
        color: AppColors.of(context).card,
        child: Icon(Icons.movie_outlined, color: AppColors.of(context).secondaryLabel),
      );
}

/// Empty / error state as the original draws it: an accent icon with a soft glow, a bold title, a grey subtitle and an
/// optional action underneath.
class EmptyState extends StatelessWidget {
  const EmptyState(
      {super.key,
      required this.icon,
      required this.title,
      this.subtitle,
      this.action,
      this.bottomInset = 0,
      this.plain = false,
      this.color,
      this.actionGap = 28});
  final IconData icon;

  /// Icon and glow colour; null = the accent.
  final Color? color;

  /// Space above [action] (OBSERVED: it differs from page to page).
  final double actionGap;

  /// A large grey icon without the accent glow (OBSERVED on WebDAV 同步).
  final bool plain;
  final String title;
  final String? subtitle;
  final Widget? action;
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + bottomInset),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (plain) ...[
            Icon(icon, size: 72, color: c.secondaryLabel),
            const SizedBox(height: 20),
          ] else ...[
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [
                  (color ?? AppColors.of(context).accent).withValues(alpha: color == null ? 0.28 : 0.16),
                  (color ?? AppColors.of(context).accent).withValues(alpha: 0)
                ]),
              ),
              child: Icon(icon, size: 44, color: color ?? AppColors.of(context).accent),
            ),
            const SizedBox(height: 28),
          ],
          Text(title,
              textAlign: TextAlign.center, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.label)),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(subtitle!, textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: c.subtitle)),
          ],
          if (action != null) ...[SizedBox(height: actionGap), action!],
        ]),
      ),
    );
  }
}

/// Error state with a retry button.
///
/// OBSERVED (a mock site failing with HTTP 500): a pink error icon (#FFB4AB in the dark theme) with a faint glow,
/// 加载失败, the reason in grey (see [describeLoadError]) and an outlined 重新加载 button with accent text.
class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.error, this.title, this.onRetry, this.bottomInset = 0});
  final Object error;
  final String? title;
  final VoidCallback? onRetry;
  final double bottomInset;

  @override
  Widget build(BuildContext context) => EmptyState(
        icon: Icons.error_outline,
        color: AppColors.dangerText(context),
        title: title ?? context.l10n.loadFailed,
        subtitle: error is String ? error as String : describeLoadError(error, context.l10n),
        bottomInset: bottomInset,
        action: onRetry == null
            ? null
            : OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.of(context).accent,
                  shape: const StadiumBorder(),
                  side: BorderSide(color: AppColors.of(context).secondaryLabel.withValues(alpha: 0.7)),
                  minimumSize: const Size(104, 39),
                  textStyle: const TextStyle(fontSize: 14),
                ),
                onPressed: onRetry,
                child: Text(context.l10n.reload),
              ),
      );
}

/// Grey poster placeholders shown while the first page of a category loads (OBSERVED on a slow mock site: poster
/// boxes with a narrower title bar under each, in the grid's own layout).
///
/// OBSERVED on the phone (2026-11-10, UZN 1.1.7 switching to a slow site): the poster boxes are a diagonal grey
/// gradient (about 7 % darker than the page at the darkest) that sweeps while loading. Before 2026-11-10 UZV's poster
/// boxes were 0 dp wide (a childless DecoratedBox under a loosely constrained Column), so only the title bars showed.
/// UZV also turns a spinner over them (the user asked for one, 2026-11-10); the original has none.
class VodSkeletonGrid extends StatefulWidget {
  const VodSkeletonGrid({super.key, this.header, this.bottomInset = 0});
  final Widget? header;
  final double bottomInset;

  /// Key of every poster placeholder.
  static const posterKey = ValueKey('vodSkeletonPoster');

  @override
  State<VodSkeletonGrid> createState() => _VodSkeletonGridState();
}

class _VodSkeletonGridState extends State<VodSkeletonGrid> with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat();

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final dark = Color.alphaBlend(c.label.withValues(alpha: 0.08), c.page);
    final light = Color.alphaBlend(c.label.withValues(alpha: 0.025), c.page);
    final columns = (MediaQuery.sizeOf(context).width / 130).floor().clamp(2, 10);
    Widget poster() => AnimatedBuilder(
          animation: _sweep,
          builder: (_, __) {
            final t = -0.4 + _sweep.value * 1.8;
            return DecoratedBox(
              key: VodSkeletonGrid.posterKey,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [dark, light, dark],
                  stops: [(t - 0.35).clamp(0.0, 1.0), t.clamp(0.0, 1.0), (t + 0.35).clamp(0.0, 1.0)],
                ),
              ),
            );
          },
        );
    return Stack(children: [
      CustomScrollView(physics: const NeverScrollableScrollPhysics(), slivers: [
        if (widget.header != null) SliverToBoxAdapter(child: widget.header),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(11, 12, 11, 12 + widget.bottomInset),
          sliver: SliverGrid(
            gridDelegate: _posterGrid(columns),
            delegate: SliverChildBuilderDelegate(
              childCount: columns * 4,
              (_, __) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(child: poster()),
                const SizedBox(height: 10),
                FractionallySizedBox(
                  widthFactor: 0.72,
                  child: Container(
                      height: 13, decoration: BoxDecoration(color: dark, borderRadius: BorderRadius.circular(3))),
                ),
                const SizedBox(height: 3),
              ]),
            ),
          ),
        ),
      ]),
      Positioned.fill(
        bottom: widget.bottomInset,
        child: const IgnorePointer(
          child: Center(child: SizedBox(width: 30, height: 30, child: CircularProgressIndicator(strokeWidth: 2.8))),
        ),
      ),
    ]);
  }
}

/// The original's filled accent button with an optional leading icon; [expand] stretches it to the available width.
/// OBSERVED: 39 dp high (添加账号, 添加配置, 登录并保存, 验证并保存, 保存).
class PrimaryButton extends StatelessWidget {
  const PrimaryButton(
      {super.key,
      required this.label,
      required this.onPressed,
      this.icon,
      this.expand = false,
      this.color,
      this.height = 39});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      backgroundColor: color ?? AppColors.of(context).accent,
      foregroundColor: color == null ? AppColors.of(context).onAccent : Colors.white,
      minimumSize: Size(expand ? double.infinity : 64, height),
      padding: const EdgeInsets.symmetric(horizontal: 22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      textStyle: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500),
    );
    final tap = onPressed == null
        ? null
        : () {
            AppHaptics.light();
            onPressed!();
          };
    return icon == null
        ? FilledButton(style: style, onPressed: tap, child: Text(label))
        : FilledButton.icon(style: style, onPressed: tap, icon: Icon(icon, size: 18), label: Text(label));
  }
}

/// A grouped settings card with an optional section label above it (the original's 数据 / 偏好 / 工具 groups).
class SettingsSection extends StatelessWidget {
  const SettingsSection(
      {super.key,
      this.title,
      required this.children,
      this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 0),
      this.dividers = true});
  final String? title;
  final List<Widget> children;
  final EdgeInsets padding;

  /// False for a card of stacked input fields, which the original draws without separators.
  final bool dividers;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0 && dividers) rows.add(Divider(height: 0.6, indent: 58, color: c.separator));
      rows.add(children[i]);
    }
    return Padding(
      padding: padding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title != null)
          Padding(
            // OBSERVED (设置, 直播设置, 备份与恢复): small bold grey headers
            padding: const EdgeInsets.fromLTRB(4, 20, 4, 9),
            child: Text(title!, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.subtitle)),
          )
        else
          const SizedBox(height: 16),
        Material(
          color: c.card,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: Padding(padding: EdgeInsets.symmetric(vertical: dividers ? 0 : 6), child: Column(children: rows)),
        ),
      ]),
    );
  }
}

/// Rounded accent-tinted square behind a settings icon.
class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, this.color});
  final IconData icon;

  /// The theme's accent when null.
  final Color? color;

  @override
  // OBSERVED: 30 dp tiles with a 16 dp icon
  Widget build(BuildContext context) {
    final color = this.color ?? AppColors.of(context).accent;
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(7)),
      child: Icon(icon, size: 16, color: color),
    );
  }
}

/// One row of a [SettingsSection]: icon tile, title, grey subtitle, and a chevron (or [trailing]).
class SettingsTile extends StatelessWidget {
  const SettingsTile(
      {super.key,
      this.icon,
      required this.title,
      this.subtitle,
      this.trailing,
      this.onTap,
      this.destructive = false,
      this.indent = 0});
  final IconData? icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool destructive;

  /// Extra left padding for a row that belongs to the one above it (OBSERVED 日志记录's 清空日志 / 导出日志: ~20 dp).
  final double indent;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final color = destructive ? AppColors.dangerText(context) : AppColors.of(context).accent;
    return InkWell(
      onTap: onTap == null
          ? null
          : () {
              AppHaptics.light();
              onTap!();
            },
      child: Padding(
        // OBSERVED: 69 dp rows with a subtitle, title 14.5, subtitle 12.5
        padding: EdgeInsets.fromLTRB(14 + indent, 13.5, 14, 13.5),
        child: Row(children: [
          if (icon != null) ...[IconTile(icon!, color: color), const SizedBox(width: 14)],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 14.5, color: destructive ? color : c.label)),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(subtitle!, style: TextStyle(fontSize: 12.5, color: c.subtitle)),
              ],
            ]),
          ),
          const SizedBox(width: 8),
          trailing ??
              (onTap == null
                  ? const SizedBox.shrink()
                  : Icon(Icons.chevron_right, color: c.secondaryLabel.withValues(alpha: 0.45), size: 20)),
        ]),
      ),
    );
  }
}

/// Segmented control styled like the original's 网络 / 本地 / 云端 and 自适应 / 亮色 / 暗色 pickers.
class AppSegmented<T> extends StatelessWidget {
  const AppSegmented(
      {super.key,
      required this.segments,
      required this.value,
      required this.onChanged,
      this.onCard = false,
      this.height = 38,
      this.strong = false});
  final Map<T, (IconData?, String)> segments;
  final T value;
  final ValueChanged<T> onChanged;

  /// Height of one segment (OBSERVED 38 on 添加订阅, 32 on 主题设置).
  final double height;

  /// OBSERVED on 主题设置: bold selected text and unselected text in the label colour instead of grey.
  final bool strong;

  /// Inside a card the track is drawn in the page colour; on the page itself it is invisible.
  final bool onCard;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final fontSize = segments.length > 3 ? 13.0 : 14.5;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: onCard ? c.page : Colors.transparent, borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        for (final e in segments.entries)
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (e.key != value) AppHaptics.selection();
                onChanged(e.key);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                height: height,
                decoration: BoxDecoration(
                  // OBSERVED on 添加订阅: the selected segment is the card colour (#2C2C2E) on the bare page
                  color: e.key == value ? c.card : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  if (e.value.$1 != null) ...[
                    Icon(e.value.$1, size: 17, color: e.key == value ? c.label : c.secondaryLabel),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(e.value.$2,
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: fontSize,
                          fontWeight: e.key == value ? (strong ? FontWeight.w700 : FontWeight.w500) : FontWeight.normal,
                          color: e.key == value || strong ? c.label : c.secondaryLabel,
                        )),
                  ),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Label above a filled text field, as on the original's 添加订阅 page: a paste button while the field is empty, a
/// clear button once it has text (OBSERVED), or a fixed [suffix] (e.g. the lock on a read-only address).
class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.keyboardType,
    this.obscure = false,
    this.paste = true,
    this.maxLines = 1,
    this.onSubmitted,
    this.onChanged,
    this.readOnly = false,
    this.suffix,
    this.padding = const EdgeInsets.fromLTRB(14, 8, 14, 8),
  });
  final EdgeInsets padding;
  final TextEditingController controller;
  final String label;
  final String? hint;
  final TextInputType? keyboardType;
  final bool obscure;
  final bool paste;
  final int maxLines;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final bool readOnly;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: padding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 13, color: c.subtitle)),
        const SizedBox(height: 8),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            Widget? suffixIcon = suffix;
            if (suffixIcon == null && !readOnly && paste) {
              suffixIcon = value.text.isEmpty
                  ? IconButton(
                      tooltip: context.l10n.paste,
                      icon: Icon(Icons.content_paste, size: 20, color: c.secondaryLabel),
                      onPressed: () async {
                        final data = await Clipboard.getData(Clipboard.kTextPlain);
                        final text = data?.text?.trim();
                        if (text != null && text.isNotEmpty) {
                          controller.text = text;
                          onChanged?.call(text);
                          onSubmitted?.call(text);
                        }
                      },
                    )
                  : IconButton(
                      icon: Icon(Icons.cancel, size: 20, color: c.secondaryLabel),
                      onPressed: () {
                        controller.clear();
                        onChanged?.call('');
                      },
                    );
            }
            return TextField(
              controller: controller,
              keyboardType: keyboardType,
              obscureText: obscure,
              readOnly: readOnly,
              maxLines: obscure ? 1 : maxLines,
              onSubmitted: onSubmitted,
              onChanged: onChanged,
              // OBSERVED: 46 px high inputs on the original's forms
              decoration: InputDecoration(
                  hintText: hint,
                  suffixIcon: suffixIcon,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
            );
          },
        ),
      ]),
    );
  }
}

/// The original's iOS-style progress HUD: a dark rounded box with a green check and a short text, centred on screen.
void showSuccessHud(BuildContext context, String text) =>
    _showHud(context, text, Icons.check_circle_outline, const Color(0xFF5BE0A0));

/// The same box with an orange warning sign (OBSERVED 该字体已存在, sign #FFA836).
void showWarningHud(BuildContext context, String text) =>
    _showHud(context, text, Icons.warning_amber_rounded, const Color(0xFFFFA836));

/// The same box with a red "!" (OBSERVED 不是有效的 uzn 备份包, sign #FF5252, still up about 3 s later).
void showErrorHud(BuildContext context, String text) =>
    _showHud(context, text, Icons.error_outline, const Color(0xFFFF5252), duration: const Duration(seconds: 3));

void _showHud(BuildContext context, String text, IconData icon, Color iconColor,
    {Duration duration = const Duration(milliseconds: 1300)}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  final entry = OverlayEntry(
    builder: (_) => IgnorePointer(
      child: Center(
        child: Material(
          color: Colors.black.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: iconColor, size: 40),
              const SizedBox(height: 12),
              Text(text, style: const TextStyle(color: Colors.white, fontSize: 15)),
            ]),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  Future<void>.delayed(duration, entry.remove);
}

/// Large accent icon with a soft glow, used as the header illustration of a settings page (e.g. 连接 TMDB).
class HeroIcon extends StatelessWidget {
  const HeroIcon(this.icon, {super.key});
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        width: 112,
        height: 112,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [
            AppColors.of(context).accent.withValues(alpha: 0.30),
            AppColors.of(context).accent.withValues(alpha: 0)
          ]),
        ),
        child: Icon(icon, size: 64, color: AppColors.of(context).accent),
      );
}

/// Padding for a [LabeledField] drawn straight on the page instead of inside a card (添加账号, 添加直播源, WebDAV 配置).
const bareFieldPadding = EdgeInsets.fromLTRB(2, 8, 2, 8);

/// Confirmation dialog; true when the user pressed [confirmLabel] (default 确定 / 删除 for [destructive]).
/// [smallTitle]: OBSERVED on some of the original's dialogs (删除字体), a title barely larger than the message.
/// [neutralButtons]: both buttons in the text colour (OBSERVED 清空日志). [plainConfirm]: 取消 keeps the accent and the
/// confirm button is in the text colour (OBSERVED 确认恢复).
Future<bool> confirmAction(BuildContext context,
    {String? title,
    required String message,
    String? confirmLabel,
    bool destructive = false,
    bool smallTitle = false,
    bool neutralButtons = false,
    bool plainConfirm = false}) async {
  final l = context.l10n;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) {
      final plain = TextButton.styleFrom(foregroundColor: AppColors.of(c).label);
      final neutral = neutralButtons ? plain : null;
      return AlertDialog(
        title: title == null ? null : Text(title, style: smallTitle ? const TextStyle(fontSize: 17) : null),
        content: Text(message),
        actions: [
          TextButton(style: neutral, onPressed: () => Navigator.pop(c, false), child: Text(l.cancel)),
          TextButton(
            style: destructive
                ? TextButton.styleFrom(foregroundColor: AppColors.dangerText(c))
                : (plainConfirm ? plain : neutral),
            onPressed: () => Navigator.pop(c, true),
            child: Text(confirmLabel ?? (destructive ? l.delete : l.ok)),
          ),
        ],
      );
    },
  );
  return ok == true;
}

/// Password field with the original's eye toggle next to the paste button.
class PasswordField extends StatefulWidget {
  const PasswordField(
      {super.key,
      required this.controller,
      required this.label,
      this.hint,
      this.padding = const EdgeInsets.fromLTRB(14, 8, 14, 8)});
  final EdgeInsets padding;
  final TextEditingController controller;
  final String label;
  final String? hint;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return LabeledField(
      controller: widget.controller,
      label: widget.label,
      hint: widget.hint,
      padding: widget.padding,
      obscure: !_visible,
      suffix: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          tooltip: context.l10n.paste,
          icon: Icon(Icons.content_paste, size: 20, color: c.secondaryLabel),
          onPressed: () async {
            final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
            if (text != null && text.isNotEmpty) widget.controller.text = text;
          },
        ),
        IconButton(
          icon: Icon(_visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
              size: 20, color: c.secondaryLabel), // OBSERVED: an open eye while hidden
          onPressed: () => setState(() => _visible = !_visible),
        ),
        const SizedBox(width: 4),
      ]),
    );
  }
}
