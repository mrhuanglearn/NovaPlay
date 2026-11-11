import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/ui_hooks.dart';
import '../models/vod.dart';
import '../l10n/l10n.dart';
import 'category_filters.dart';
import 'load_error.dart';
import 'widgets.dart';

/// `/video/sub-category`: one category with its filter rows (year, area, sort, ...) and paging.
class SubCategoryScreen extends ConsumerStatefulWidget {
  const SubCategoryScreen({super.key, required this.typeId});
  final String typeId;
  @override
  ConsumerState<SubCategoryScreen> createState() => _SubCategoryScreenState();
}

class _SubCategoryScreenState extends ConsumerState<SubCategoryScreen> {
  final Map<String, String> _filters = {};
  final List<VodItem> _items = [];
  int _page = 1;
  bool _loading = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _more());
  }

  Future<void> _more() async {
    if (_loading || _done) return;
    final filters = Map<String, String>.from(_filters);
    setState(() => _loading = true);
    try {
      final site = ref.read(currentSiteProvider);
      if (site == null) return;
      final res = await ref
          .read(videoCategoryFeedProvider)((siteKey: site.key, typeId: widget.typeId, page: _page, filters: filters));
      if (!mounted || res == null || !_sameFilters(filters)) return;
      setState(() {
        _items.addAll(res.items);
        _done = !res.hasMore || res.items.isEmpty;
        _page++;
      });
    } catch (e) {
      if (mounted) showToast(describeLoadError(e, context.l10n));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _sameFilters(Map<String, String> f) =>
      f.length == _filters.length && f.entries.every((e) => _filters[e.key] == e.value);

  void _setFilter(String key, String value) {
    setState(() {
      if (value.isEmpty) {
        _filters.remove(key);
      } else {
        _filters[key] = value;
      }
      _items.clear();
      _page = 1;
      _done = false;
      _loading = false;
    });
    _more();
  }

  @override
  Widget build(BuildContext context) {
    final home = ref.watch(videoFeedProvider).valueOrNull;
    final category = home?.categories.where((c) => c.id == widget.typeId).firstOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(category?.name ?? widget.typeId)),
      body: Column(children: [
        if ((category?.filters ?? const <VodFilter>[]).isNotEmpty)
          CategoryFilterBar(filters: category!.filters, chosen: _filters, onChanged: (f, v) => _setFilter(f.key, v)),
        Expanded(
          child: _items.isEmpty && !_loading
              ? EmptyState(icon: Icons.search_off, title: context.l10n.noData, subtitle: context.l10n.nothingHere)
              : VodGrid(items: _items, onNearEnd: _more),
        ),
      ]),
    );
  }
}
