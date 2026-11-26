import 'package:flutter/material.dart';

import '../state/cast_controller.dart';
import 'remote_sheet.dart';

/// A small floating window inside TapCast (drag it anywhere) while something plays on the TV.
/// Outside the app, the notification has the buttons.
class FloatingMini extends StatefulWidget {
  const FloatingMini({super.key, required this.controller});

  final CastController controller;

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
      listenable: c,
      builder: (context, _) {
        if (!c.cast.active) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final s = c.cast;
        final thumb = thumbFor(s.uri);
        final title = (s.title?.isNotEmpty ?? false) ? s.title! : 'Casting to ${s.device}';
        final playing = !s.paused;

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
                    onTap: () => showRemote(context, c),
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
                                if (thumb != null)
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
                                        _btn(playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                            () => c.control(playing ? 'pause' : 'resume')),
                                        _btn(Icons.skip_next_rounded, () => c.control('next')),
                                        _btn(Icons.close_rounded, () => c.control('stop')),
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
