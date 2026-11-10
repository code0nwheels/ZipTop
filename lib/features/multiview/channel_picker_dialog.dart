import 'package:flutter/material.dart';

import '../../core/models/catalog.dart';
import '../../core/stores/catalog_store.dart';
import '../../theme.dart';

/// Picks one channel: search across everything, or browse a category.
/// Returns the channel, or null when dismissed.
class ChannelPickerDialog extends StatefulWidget {
  const ChannelPickerDialog({
    super.key,
    required this.catalog,
    required this.title,
    this.excludeIds = const {},
  });

  final CatalogStore catalog;
  final String title;

  /// Channels already on screen, shown as taken.
  final Set<String> excludeIds;

  static Future<Channel?> show(
    BuildContext context, {
    required CatalogStore catalog,
    required String title,
    Set<String> excludeIds = const {},
  }) =>
      showDialog<Channel>(
        context: context,
        builder: (_) =>
            ChannelPickerDialog(catalog: catalog, title: title, excludeIds: excludeIds),
      );

  @override
  State<ChannelPickerDialog> createState() => _ChannelPickerDialogState();
}

class _ChannelPickerDialogState extends State<ChannelPickerDialog> {
  final _search = TextEditingController();
  late String? _categoryId = _initialCategory();

  String? _initialCategory() {
    final catalog = widget.catalog;
    final favorites = catalog.category(CategoryIds.favorites);
    if (favorites != null && !favorites.hidden && catalog.channelsIn(favorites).isNotEmpty) {
      return favorites.id;
    }
    return CategoryIds.all;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalog = widget.catalog;
    final categories = catalog.visibleCategories;
    final query = _search.text.trim().toLowerCase();
    final selected = catalog.category(_categoryId);

    final List<Channel> channels;
    if (query.isNotEmpty) {
      channels = [
        for (final c in catalog.allChannels)
          if (c.name.toLowerCase().contains(query) ||
              (c.nowPlaying?.title?.toLowerCase().contains(query) ?? false))
            c,
      ];
    } else if (selected != null) {
      channels = catalog.channelsIn(selected);
    } else {
      channels = catalog.allChannels;
    }

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 10),
              child: Row(
                children: [
                  Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextField(
                      controller: _search,
                      autofocus: true,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'Search channels and shows',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        filled: true,
                        fillColor: ZipColors.background,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: 200,
                    child: Opacity(
                      opacity: query.isEmpty ? 1 : 0.45,
                      child: ListView(
                        children: [
                          for (final c in categories)
                            ListTile(
                              dense: true,
                              selected: query.isEmpty && c.id == _categoryId,
                              selectedTileColor: ZipColors.surfaceHigh,
                              title: Text(
                                c.icon == null || c.icon!.isEmpty
                                    ? c.name
                                    : '${c.icon}  ${c.name}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => setState(() {
                                _search.clear();
                                _categoryId = c.id;
                              }),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: channels.isEmpty
                        ? const Center(
                            child: Text(
                              'No channels found.',
                              style: TextStyle(color: ZipColors.textMuted),
                            ),
                          )
                        : ListView.builder(
                            itemCount: channels.length,
                            itemExtent: 54,
                            itemBuilder: (context, index) {
                              final channel = channels[index];
                              final taken = widget.excludeIds.contains(channel.id);
                              final title = channel.nowPlaying?.title;
                              return ListTile(
                                dense: true,
                                enabled: !taken,
                                leading: SizedBox(
                                  width: 40,
                                  child: Text(
                                    channel.number?.toString() ?? '',
                                    style: const TextStyle(color: ZipColors.textMuted),
                                  ),
                                ),
                                title: Text(
                                  channel.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: taken
                                    ? const Text('Already on screen')
                                    : (title == null || title.isEmpty
                                        ? null
                                        : Text(
                                            title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          )),
                                onTap: () => Navigator.of(context).pop(channel),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
