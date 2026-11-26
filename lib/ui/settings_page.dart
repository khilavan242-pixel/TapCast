import 'package:flutter/material.dart';

import '../state/cast_controller.dart';
import 'devices_sheet.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.controller});

  final CastController controller;

  static const _shuffleHelp = [
    'Plays the up-next videos in order.',
    'Plays up-next videos in any order.',
    'Random, but keeps to videos that fit and never repeats one.',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('TV', style: theme.textTheme.titleMedium),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.tv_rounded),
              title: Text(c.device?.name ?? 'No TV chosen'),
              subtitle: const Text('Tap to choose another TV'),
              onTap: () => showDevicesSheet(context, c),
              trailing: c.device == null ? null : TextButton(onPressed: c.forgetDevice, child: const Text('Forget')),
            ),
            const SizedBox(height: 16),
            Text('Next videos', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('In order')),
                ButtonSegment(value: 1, label: Text('Shuffle')),
                ButtonSegment(value: 2, label: Text('Smart')),
              ],
              selected: {c.shuffle},
              onSelectionChanged: (s) => c.setShuffle(s.first),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_shuffleHelp[c.shuffle], style: theme.textTheme.bodySmall),
            ),
            const SizedBox(height: 24),
            Text('Theme', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'system', label: Text('System')),
                ButtonSegment(value: 'light', label: Text('Light')),
                ButtonSegment(value: 'dark', label: Text('Dark')),
              ],
              selected: {c.store.themeMode},
              onSelectionChanged: (s) => c.setThemeMode(s.first),
            ),
            const SizedBox(height: 24),
            Text('How it works', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'Share a video from the YouTube app to TapCast and it plays on your TV straight away, '
              'then the next videos follow by themselves. You can also tap any video on the YouTube '
              'page here, or pick files from your phone.\n\n'
              'TapCast only runs while it is casting. The X on the notification, or swiping the app '
              'away from recent apps, closes it completely.',
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: c.exitApp,
              icon: const Icon(Icons.power_settings_new_rounded),
              label: const Text('Stop casting and close TapCast'),
            ),
            const SizedBox(height: 16),
            Text('TapCast 0.4.0', style: theme.textTheme.bodySmall),
          ],
        );
      },
    );
  }
}
