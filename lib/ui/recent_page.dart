import 'package:flutter/material.dart';

import '../state/cast_controller.dart';
import 'devices_sheet.dart';

/// Videos cast before: tap one to play it again.
class RecentPage extends StatelessWidget {
  const RecentPage({super.key, required this.controller});

  final CastController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final items = controller.recent;
        if (items.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text('Videos you cast will show up here.', style: theme.textTheme.bodyLarge),
            ),
          );
        }
        return Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: controller.clearRecent, child: const Text('Clear')),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final r = items[i];
                  return ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 96,
                        height: 54,
                        child: Image.network(
                          'https://i.ytimg.com/vi/${r.id}/mqdefault.jpg',
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black26),
                        ),
                      ),
                    ),
                    title: Text(r.title.isEmpty ? 'YouTube video' : r.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () async {
                      if (!await ensureDevice(context, controller)) return;
                      final ok = await controller.castVideo(r.id, title: r.title);
                      if (!ok && controller.takeUnreachable() && context.mounted) {
                        await offerPhone(context, controller, () {
                          controller.native.viewExternal('https://www.youtube.com/watch?v=${r.id}');
                        });
                      }
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
