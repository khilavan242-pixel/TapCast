import 'package:flutter/material.dart';

import '../state/cast_controller.dart';
import '../utils/url_utils.dart';

String _clock(int s) {
  if (s < 0) s = 0;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// The picture to show for what plays on the TV (YouTube thumbnail), or null for local files.
String? thumbFor(String? uri) {
  if (uri == null) return null;
  final id = UrlUtils.videoId(uri);
  return id == null ? null : 'https://i.ytimg.com/vi/$id/mqdefault.jpg';
}

Future<void> showRemote(BuildContext context, CastController c) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _Remote(controller: c),
  );
}

class _Remote extends StatefulWidget {
  const _Remote({required this.controller});

  final CastController controller;

  @override
  State<_Remote> createState() => _RemoteState();
}

class _RemoteState extends State<_Remote> {
  double? _drag; // seconds while the slider is being dragged
  double? _vol;

  static const _shuffleNames = ['Shuffle off', 'Shuffle', 'Smart shuffle'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.cast;
        if (!s.active && s.status != 'ended') {
          // Casting stopped: close the remote.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
          });
        }
        final dur = c.progress.duration;
        final pos = (_drag ?? c.progress.position.toDouble()).clamp(0, dur > 0 ? dur.toDouble() : 1.0).toDouble();
        final thumb = thumbFor(s.uri);
        final vol = (_vol ?? (s.volume >= 0 ? s.volume.toDouble() : 0)).clamp(0, 100).toDouble();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (thumb != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Image.network(thumb, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black26)),
                    ),
                  ),
                const SizedBox(height: 12),
                Text(
                  s.title?.isNotEmpty == true ? s.title! : 'Casting',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
                Text('on ${s.device}', style: theme.textTheme.bodySmall),
                Slider(
                  value: pos,
                  max: dur > 0 ? dur.toDouble() : 1,
                  onChanged: dur > 0 ? (v) => setState(() => _drag = v) : null,
                  onChangeEnd: (v) {
                    c.control('seek', value: v.round());
                    setState(() => _drag = null);
                  },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [Text(_clock(pos.round())), Text(dur > 0 ? _clock(dur) : '')],
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      tooltip: _shuffleNames[c.shuffle],
                      onPressed: () => c.setShuffle((c.shuffle + 1) % 3),
                      icon: Icon(
                        c.shuffle == 2 ? Icons.auto_awesome_rounded : Icons.shuffle_rounded,
                        color: c.shuffle == 0 ? null : theme.colorScheme.primary,
                      ),
                    ),
                    IconButton(iconSize: 36, onPressed: () => c.control('previous'), icon: const Icon(Icons.skip_previous_rounded)),
                    IconButton.filled(
                      iconSize: 40,
                      onPressed: () => c.control(s.paused ? 'resume' : 'pause'),
                      icon: Icon(s.paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
                    ),
                    IconButton(iconSize: 36, onPressed: () => c.control('next'), icon: const Icon(Icons.skip_next_rounded)),
                    IconButton(tooltip: 'Stop', onPressed: () => c.control('stop'), icon: const Icon(Icons.stop_rounded)),
                  ],
                ),
                Row(
                  children: [
                    const Icon(Icons.volume_up_rounded),
                    Expanded(
                      child: Slider(
                        value: vol,
                        max: 100,
                        onChanged: (v) => setState(() => _vol = v),
                        onChangeEnd: (v) {
                          c.control('volume', value: v.round());
                          setState(() => _vol = null);
                        },
                      ),
                    ),
                  ],
                ),
                Text(
                  '${_shuffleNames[c.shuffle]} · ${s.index + 1} of ${s.count}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
