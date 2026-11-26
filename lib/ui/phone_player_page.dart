import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../state/cast_controller.dart';

String _clock(int s) {
  if (s < 0) s = 0;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

Future<void> openPhonePlayer(BuildContext context, CastController c) {
  return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PhonePlayerPage(controller: c)));
}

/// The phone's own player. Pressing Home turns a video into a floating window.
class PhonePlayerPage extends StatefulWidget {
  const PhonePlayerPage({super.key, required this.controller});

  final CastController controller;

  @override
  State<PhonePlayerPage> createState() => _PhonePlayerPageState();
}

class _PhonePlayerPageState extends State<PhonePlayerPage> {
  double? _drag;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.controller.phone.setPageOpen(true));
  }

  @override
  void dispose() {
    final p = widget.controller.phone;
    WidgetsBinding.instance.addPostFrameCallback((_) => p.setPageOpen(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.controller.phone;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        if (!p.active) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
          });
          return const Scaffold(backgroundColor: Colors.black);
        }
        final vc = p.controller;
        final cur = p.current;
        final thumb = cur == null ? null : 'https://i.ytimg.com/vi/${cur.id}/hqdefault.jpg';
        final ready = vc != null && vc.value.isInitialized;
        Widget picture;
        if (ready && !p.audioOnly) {
          picture = AspectRatio(aspectRatio: vc.value.aspectRatio, child: VideoPlayer(vc));
        } else {
          picture = AspectRatio(
            aspectRatio: p.audioOnly ? 1 : 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (thumb != null)
                  Image.network(thumb, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black26)),
                if (p.loading) const Center(child: CircularProgressIndicator()),
              ],
            ),
          );
        }
        if (p.inPip) {
          return Scaffold(backgroundColor: Colors.black, body: Center(child: picture));
        }
        final dur = ready ? vc.value.duration.inSeconds : 0;
        final pos = (_drag ?? (ready ? vc.value.position.inSeconds.toDouble() : 0)).clamp(0, dur > 0 ? dur.toDouble() : 1.0).toDouble();
        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              tooltip: 'Minimise',
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            title: const Text('Playing on this phone'),
            actions: [
              IconButton(tooltip: 'Close', icon: const Icon(Icons.close_rounded), onPressed: p.stop),
            ],
          ),
          body: Column(
            children: [
              ClipRRect(borderRadius: BorderRadius.circular(p.audioOnly ? 16 : 0), child: picture),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(
                  (cur?.title.isNotEmpty ?? false) ? cur!.title : 'YouTube',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (p.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(p.error!, style: TextStyle(color: theme.colorScheme.error)),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Slider(
                  value: pos,
                  max: dur > 0 ? dur.toDouble() : 1,
                  onChanged: dur > 0 ? (v) => setState(() => _drag = v) : null,
                  onChangeEnd: (v) {
                    p.seek(v.round());
                    setState(() => _drag = null);
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [Text(_clock(pos.round())), Text(dur > 0 ? _clock(dur) : '')],
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    tooltip: const ['Repeat off', 'Repeat all', 'Repeat one'][p.repeat],
                    onPressed: p.cycleRepeat,
                    icon: Icon(
                      p.repeat == 2 ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                      color: p.repeat == 0 ? null : theme.colorScheme.primary,
                    ),
                  ),
                  IconButton(iconSize: 36, onPressed: p.previous, icon: const Icon(Icons.skip_previous_rounded)),
                  IconButton.filled(
                    iconSize: 40,
                    onPressed: p.togglePlay,
                    icon: Icon(p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                  ),
                  IconButton(iconSize: 36, onPressed: () => p.next(), icon: const Icon(Icons.skip_next_rounded)),
                  const SizedBox(width: 48),
                ],
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                child: Align(alignment: Alignment.centerLeft, child: Text('Up next', style: theme.textTheme.titleSmall)),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: p.queue.length,
                  itemBuilder: (_, i) {
                    final q = p.queue[i];
                    final now = i == p.index;
                    return ListTile(
                      dense: true,
                      selected: now,
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: SizedBox(
                          width: 64,
                          height: 36,
                          child: Image.network(
                            'https://i.ytimg.com/vi/${q.id}/mqdefault.jpg',
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black26),
                          ),
                        ),
                      ),
                      title: Text(q.title.isEmpty ? 'YouTube video' : q.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: now ? const Icon(Icons.equalizer_rounded) : null,
                      onTap: now ? null : () => p.jumpTo(i),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
