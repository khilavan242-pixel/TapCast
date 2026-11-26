import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../state/cast_controller.dart';
import 'phone_player_page.dart';
import 'remote_sheet.dart';

/// A small floating window inside TapCast (drag it anywhere) while something plays on the TV
/// or on the phone. Outside the app, the notification has the buttons.
class FloatingMini extends StatefulWidget {
  const FloatingMini({super.key, required this.controller, this.phoneInline = false});

  final CastController controller;

  /// True while the page itself shows the phone player (so no floating window is needed).
  final bool phoneInline;

  @override
  State<FloatingMini> createState() => _FloatingMiniState();
}

class _FloatingMiniState extends State<FloatingMini> {
  static const double _w = 200;
  static const double _h = 112 + 30;

  Offset? _pos;

  CastController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, c.phone]),
      builder: (context, _) {
        final p = c.phone;
        final phoneOn = p.active && !p.pageOpen && !widget.phoneInline;
        final castOn = c.cast.active;
        if (!phoneOn && !castOn) return const SizedBox.shrink();
        final theme = Theme.of(context);

        final String? thumb;
        final String title;
        final bool playing;
        final VideoPlayerController? live;
        if (phoneOn) {
          final cur = p.current;
          thumb = cur == null ? null : 'https://i.ytimg.com/vi/${cur.id}/mqdefault.jpg';
          title = (cur?.title.isNotEmpty ?? false) ? cur!.title : 'Playing on this phone';
          playing = p.playing;
          live = (!p.audioOnly && (p.controller?.value.isInitialized ?? false)) ? p.controller : null;
        } else {
          final s = c.cast;
          thumb = thumbFor(s.uri);
          title = (s.title?.isNotEmpty ?? false) ? s.title! : 'Casting to ${s.device}';
          playing = !s.paused;
          live = null;
        }

        return LayoutBuilder(
          builder: (context, box) {
            final maxX = (box.maxWidth - _w).clamp(0.0, double.infinity);
            final maxY = (box.maxHeight - _h).clamp(0.0, double.infinity);
            final pos = _pos ?? Offset(maxX - 12 < 0 ? 0 : maxX - 12, maxY - 12 < 0 ? 0 : maxY - 12);
            final at = Offset(pos.dx.clamp(0.0, maxX), pos.dy.clamp(0.0, maxY));
            return Stack(
              children: [
                Positioned(
                  left: at.dx,
                  top: at.dy,
                  width: _w,
                  child: GestureDetector(
                    onPanUpdate: (d) => setState(() => _pos = Offset(
                          (at.dx + d.delta.dx).clamp(0.0, maxX),
                          (at.dy + d.delta.dy).clamp(0.0, maxY),
                        )),
                    onTap: () => phoneOn ? openPhonePlayer(context, c) : showRemote(context, c),
                    child: Material(
                      elevation: 8,
                      borderRadius: BorderRadius.circular(14),
                      clipBehavior: Clip.antiAlias,
                      color: theme.colorScheme.surfaceContainerHigh,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            height: 112,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (live != null)
                                  FittedBox(
                                    fit: BoxFit.cover,
                                    clipBehavior: Clip.hardEdge,
                                    child: SizedBox(
                                      width: live.value.size.width <= 0 ? 16 : live.value.size.width,
                                      height: live.value.size.height <= 0 ? 9 : live.value.size.height,
                                      child: VideoPlayer(live),
                                    ),
                                  )
                                else if (thumb != null)
                                  Image.network(thumb, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black26))
                                else
                                  const ColoredBox(color: Colors.black26, child: Icon(Icons.tv_rounded)),
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: Container(
                                    color: Colors.black54,
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                      children: [
                                        _btn(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, () {
                                          if (phoneOn) {
                                            p.togglePlay();
                                          } else {
                                            c.control(playing ? 'pause' : 'resume');
                                          }
                                        }),
                                        _btn(Icons.skip_next_rounded, () {
                                          if (phoneOn) {
                                            p.next();
                                          } else {
                                            c.control('next');
                                          }
                                        }),
                                        _btn(Icons.close_rounded, () {
                                          if (phoneOn) {
                                            p.stop();
                                          } else {
                                            c.control('stop');
                                          }
                                        }),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            child: SizedBox(
                              width: double.infinity,
                              child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _btn(IconData icon, VoidCallback onTap) => IconButton(
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 40, minHeight: 32),
        padding: EdgeInsets.zero,
        color: Colors.white,
        onPressed: onTap,
        icon: Icon(icon, size: 24),
      );
}
