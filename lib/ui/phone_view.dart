import 'dart:async';

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

/// The picture (video, or the song's cover) with YouTube-style controls on top:
/// previous / play-pause / next in the middle, time and a thin seek bar at the bottom.
/// Tap it to show or hide the buttons.
class PhoneView extends StatefulWidget {
  const PhoneView({super.key, required this.controller, this.inline = false, this.onExpand, this.square = false});

  final CastController controller;

  /// True when it sits on top of the web page (adds a close button and an expand button).
  final bool inline;
  final VoidCallback? onExpand;

  /// Music on the full player screen: a big square cover.
  final bool square;

  @override
  State<PhoneView> createState() => _PhoneViewState();
}

class _PhoneViewState extends State<PhoneView> {
  bool _show = true;
  Timer? _hide;
  double? _drag;

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  void _poke() {
    setState(() => _show = true);
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted && widget.controller.phone.playing) setState(() => _show = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.controller.phone;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final vc = p.controller;
        final cur = p.current;
        final ready = vc != null && vc.value.isInitialized;
        final thumb = cur == null ? null : 'https://i.ytimg.com/vi/${cur.id}/mqdefault.jpg';
        final dur = ready ? vc.value.duration.inSeconds : 0;
        final posNow = ready ? vc.value.position.inSeconds.toDouble() : 0.0;
        final pos = (_drag ?? posNow).clamp(0, dur > 0 ? dur.toDouble() : 1.0).toDouble();
        final controls = _show || !p.playing || p.loading;

        Widget picture;
        if (ready && !p.audioOnly) {
          picture = Center(child: AspectRatio(aspectRatio: vc.value.aspectRatio, child: VideoPlayer(vc)));
        } else {
          picture = thumb == null
              ? const SizedBox.expand()
              : Image.network(thumb, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black26));
        }

        Widget round(IconData icon, VoidCallback? onTap, {double size = 30, double pad = 8}) => Material(
              color: Colors.black38,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTap,
                child: Padding(padding: EdgeInsets.all(pad), child: Icon(icon, color: Colors.white, size: size)),
              ),
            );

        final box = Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Colors.black),
            picture,
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (_show && p.playing) {
                    setState(() => _show = false);
                  } else {
                    _poke();
                  }
                },
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  opacity: controls ? 1 : 0,
                  child: IgnorePointer(
                    ignoring: !controls,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        const ColoredBox(color: Colors.black38),
                        Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              round(Icons.skip_previous_rounded, () {
                                _poke();
                                p.previous();
                              }),
                              const SizedBox(width: 22),
                              if (p.loading)
                                const SizedBox(
                                  width: 56,
                                  height: 56,
                                  child: Padding(
                                    padding: EdgeInsets.all(10),
                                    child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                                  ),
                                )
                              else
                                round(p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, () {
                                  _poke();
                                  p.togglePlay();
                                }, size: 40, pad: 8),
                              const SizedBox(width: 22),
                              round(Icons.skip_next_rounded, () {
                                _poke();
                                p.next();
                              }),
                            ],
                          ),
                        ),
                        if (widget.inline)
                          Positioned(
                            top: 4,
                            right: 4,
                            child: round(Icons.close_rounded, p.stop, size: 20, pad: 6),
                          ),
                        Positioned(
                          left: 12,
                          bottom: 14,
                          child: Text(
                            dur > 0 ? '${_clock(pos.round())} / ${_clock(dur)}' : (p.loading ? 'Loading…' : ''),
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (widget.inline && widget.onExpand != null)
                          Positioned(
                            right: 8,
                            bottom: 8,
                            child: IconButton(
                              visualDensity: VisualDensity.compact,
                              color: Colors.white,
                              onPressed: widget.onExpand,
                              icon: const Icon(Icons.open_in_full_rounded, size: 20),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // The thin seek bar stays visible, like in the YouTube app.
            Positioned(
              left: 0,
              right: 0,
              bottom: -2,
              height: 14,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2.5,
                  thumbShape: RoundSliderThumbShape(enabledThumbRadius: controls ? 6 : 0),
                  overlayShape: SliderComponentShape.noOverlay,
                  activeTrackColor: Colors.red,
                  inactiveTrackColor: Colors.white30,
                  thumbColor: Colors.red,
                  trackShape: const RectangularSliderTrackShape(),
                ),
                child: Slider(
                  value: pos,
                  max: dur > 0 ? dur.toDouble() : 1,
                  onChanged: dur > 0 ? (v) => setState(() => _drag = v) : null,
                  onChangeEnd: (v) {
                    p.seek(v.round());
                    setState(() => _drag = null);
                    _poke();
                  },
                ),
              ),
            ),
          ],
        );

        if (widget.square) {
          return AspectRatio(aspectRatio: 1, child: ClipRRect(borderRadius: BorderRadius.circular(16), child: box));
        }
        return AspectRatio(aspectRatio: 16 / 9, child: box);
      },
    );
  }
}

/// The whole floating (picture-in-picture) window: just the video.
class PhonePipView extends StatelessWidget {
  const PhonePipView({super.key, required this.controller});

  final CastController controller;

  @override
  Widget build(BuildContext context) {
    final p = controller.phone;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final vc = p.controller;
        final ok = vc != null && vc.value.isInitialized;
        return ColoredBox(
          color: Colors.black,
          child: Center(
            child: ok ? AspectRatio(aspectRatio: vc.value.aspectRatio, child: VideoPlayer(vc)) : const CircularProgressIndicator(),
          ),
        );
      },
    );
  }
}
