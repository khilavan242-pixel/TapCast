import 'package:flutter/material.dart';

import '../models/cast.dart';
import '../state/cast_controller.dart';

/// Lists the TVs found on the Wi-Fi; choosing one remembers it for next time.
/// Returns true when a TV is chosen.
Future<bool> showDevicesSheet(BuildContext context, CastController c) async {
  c.search();
  final chosen = await showModalBottomSheet<CastDevice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _DevicesSheet(controller: c),
  );
  if (chosen != null) c.chooseDevice(chosen);
  return chosen != null;
}

/// True when a TV is already chosen, otherwise asks for one first.
Future<bool> ensureDevice(BuildContext context, CastController c) async {
  if (c.device != null) return true;
  return showDevicesSheet(context, c);
}

class _DevicesSheet extends StatelessWidget {
  const _DevicesSheet({required this.controller});

  final CastController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('Cast to', style: theme.textTheme.titleLarge)),
                    if (c.searching)
                      const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                    else
                      TextButton.icon(
                        onPressed: c.search,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Search again'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (c.found.isEmpty && !c.searching)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'No TV found. Make sure the TV is on and on the same Wi-Fi as this phone.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                for (final d in c.found)
                  ListTile(
                    leading: const Icon(Icons.tv_rounded),
                    title: Text(d.name),
                    trailing: c.device?.controlUrl == d.controlUrl ? const Icon(Icons.check_rounded) : null,
                    onTap: () => Navigator.of(context).pop(d),
                  ),
                if (c.device != null && !c.found.any((d) => d.controlUrl == c.device!.controlUrl))
                  ListTile(
                    leading: const Icon(Icons.tv_rounded),
                    title: Text(c.device!.name),
                    subtitle: const Text('Last used'),
                    trailing: const Icon(Icons.check_rounded),
                    onTap: () => Navigator.of(context).pop(c.device),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The TV did not answer: ask whether to play on the phone instead.
/// [onPhone] runs when the person says yes.
Future<void> offerPhone(BuildContext context, CastController c, VoidCallback onPhone) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text("Can't reach ${c.device?.name ?? 'the TV'}"),
      content: const Text('Play on phone?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Play on phone')),
      ],
    ),
  );
  if (yes == true) onPhone();
}
