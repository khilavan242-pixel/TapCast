import 'package:flutter/material.dart';

import '../models/cast.dart';
import '../state/cast_controller.dart';
import 'devices_sheet.dart';

/// Videos and songs from the phone, played on the TV.
class FilesPage extends StatefulWidget {
  const FilesPage({super.key, required this.controller});

  final CastController controller;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  List<CastItem> _items = const [];

  CastController get c => widget.controller;

  Future<void> _pick() async {
    final picked = await c.pickMedia();
    if (picked.isNotEmpty && mounted) setState(() => _items = picked);
  }

  Future<void> _play(int from) async {
    if (!await ensureDevice(context, c)) return;
    final ok = await c.castFiles(_items.sublist(from));
    if (!mounted) return;
    if (!ok && c.takeUnreachable()) {
      final first = _items[from];
      await offerPhone(context, c, () => c.native.viewExternal(first.uri, mime: first.mime));
      return;
    }
    final msg = ok ? 'Casting to ${c.device?.name ?? 'TV'}…' : (c.takeMessage() ?? 'Could not cast');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Wrap(
            spacing: 12,
            children: [
              FilledButton.icon(
                onPressed: _pick,
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('Choose videos or songs'),
              ),
              if (_items.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: () => _play(0),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Play all on TV'),
                ),
            ],
          ),
        ),
        Expanded(
          child: _items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'Pick videos, songs or pictures from this phone, then tap one to play it on the TV.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _items.length,
                  itemBuilder: (_, i) {
                    final it = _items[i];
                    return ListTile(
                      leading: Icon(it.mime.startsWith('audio') ? Icons.music_note_rounded : Icons.movie_rounded),
                      title: Text(it.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: const Icon(Icons.cast_rounded),
                      onTap: () => _play(i),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
