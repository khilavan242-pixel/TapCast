import 'package:flutter/material.dart';

import '../state/cast_controller.dart';

/// Saved pages, shown as small logos only. Tap one to open it; press and hold to remove.
class BookmarksPage extends StatelessWidget {
  const BookmarksPage({super.key, required this.controller, required this.onOpen});

  final CastController controller;
  final void Function(String url) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final items = controller.bookmarks;
        if (items.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'Open a page, then use the ⋮ menu and choose "Add bookmark".',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
            ),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 84,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
          ),
          itemCount: items.length,
          itemBuilder: (_, i) {
            final b = items[i];
            final host = Uri.tryParse(b.url)?.host ?? '';
            return Tooltip(
              message: b.title.isEmpty ? host : b.title,
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => onOpen(b.url),
                onLongPress: () async {
                  final remove = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Remove bookmark?'),
                      content: Text(b.title.isEmpty ? host : b.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
                      ],
                    ),
                  );
                  if (remove == true) controller.toggleBookmark(b.url, b.title);
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  alignment: Alignment.center,
                  child: Image.network(
                    'https://www.google.com/s2/favicons?domain=$host&sz=128',
                    width: 40,
                    height: 40,
                    errorBuilder: (_, __, ___) => const Icon(Icons.language_rounded, size: 36),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
