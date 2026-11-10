import 'package:flutter/material.dart';

import '../../core/models/catalog.dart';
import '../../core/stores/catalog_store.dart';
import '../../theme.dart';

/// Show, hide and reorder the channel rows. Every change is saved to the
/// account straight away, so it applies on the viewer's other devices too.
class CategoriesDialog extends StatefulWidget {
  const CategoriesDialog({super.key, required this.catalog});

  final CatalogStore catalog;

  @override
  State<CategoriesDialog> createState() => _CategoriesDialogState();
}

class _CategoriesDialogState extends State<CategoriesDialog> {
  CategoryPrefs? _prefs;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final prefs = await widget.catalog.loadPreferences();
      if (mounted) setState(() => _prefs = prefs);
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't load categories");
    }
  }

  Future<void> _save(CategoryPrefsUpdate update, String failure) async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final prefs = await widget.catalog.updatePreferences(update);
      if (mounted) setState(() => _prefs = prefs);
    } catch (_) {
      messenger?.showSnackBar(SnackBar(content: Text(failure)));
      // Put the lists back to what the server has.
      await _load();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Sends only the one change, so an edit made on another device still stands.
  void _setHidden(CategoryPref category, bool hidden) {
    _save(
      hidden
          ? CategoryPrefsUpdate(hide: [category.id])
          : CategoryPrefsUpdate(show: [category.id]),
      "Couldn't save categories",
    );
  }

  /// [to] is the index the row ends up at, after its removal from [from].
  void _reorder(List<String> order, int from, int to) {
    final next = [...order];
    final moved = next.removeAt(from);
    next.insert(to, moved);
    // Show the new order at once; the server's answer replaces it.
    final prefs = _prefs!;
    setState(
      () => _prefs = CategoryPrefs(
        order: next,
        hidden: prefs.hidden,
        categories: prefs.categories,
      ),
    );
    _save(CategoryPrefsUpdate(order: next), "Couldn't save order");
  }

  @override
  Widget build(BuildContext context) {
    final prefs = _prefs;
    final text = Theme.of(context).textTheme;
    final byId = {
      if (prefs != null)
        for (final c in prefs.categories) c.id: c,
    };

    Widget body;
    if (_error != null) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    } else if (prefs == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = TabBarView(
        children: [
          prefs.categories.isEmpty
              ? const Center(child: Text('No categories to manage'))
              : ListView(
                  children: [
                    for (final c in prefs.categories)
                      SwitchListTile(
                        dense: true,
                        title: Text(_label(c)),
                        subtitle: Text('${c.count} channels'),
                        value: !c.hidden,
                        onChanged: _saving ? null : (shown) => _setHidden(c, !shown),
                      ),
                  ],
                ),
          prefs.order.length < 2
              ? const Center(child: Text('Nothing to reorder'))
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: prefs.order.length,
                  onReorderItem: (from, to) {
                    if (!_saving) _reorder(prefs.order, from, to);
                  },
                  itemBuilder: (context, index) {
                    final id = prefs.order[index];
                    final c = byId[id];
                    final name = c == null ? id : _label(c);
                    return ListTile(
                      key: ValueKey(id),
                      dense: true,
                      title: Text(c?.hidden == true ? '$name (hidden)' : name),
                      trailing: ReorderableDragStartListener(
                        index: index,
                        child: const MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: Icon(Icons.drag_handle, color: ZipColors.textMuted),
                        ),
                      ),
                    );
                  },
                ),
        ],
      );
    }

    return DefaultTabController(
      length: 2,
      child: Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 680),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 12, 0),
                child: Row(
                  children: [
                    Text('Categories', style: text.headlineSmall),
                    const SizedBox(width: 12),
                    if (_saving)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const TabBar(tabs: [Tab(text: 'Show / hide'), Tab(text: 'Order')]),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }

  String _label(CategoryPref c) {
    final icon = c.icon;
    return icon == null || icon.isEmpty ? c.name : '$icon  ${c.name}';
  }
}
