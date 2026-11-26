import 'package:flutter/material.dart';

import '../state/cast_controller.dart';
import 'phone_view.dart';

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
        final cur = p.current;
        if (p.inPip && !p.audioOnly) {
          return Scaffold(backgroundColor: Colors.black, body: PhonePipView(controller: widget.controller));
        }
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
              if (p.audioOnly)
                Padding(
                  padding: const EdgeInsets.fromLTRB(40, 8, 40, 0),
                  child: PhoneView(controller: widget.controller, square: true),
                )
              else
                PhoneView(controller: widget.controller),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        (cur?.title.isNotEmpty ?? false) ? cur!.title : 'Loading…',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: const ['Repeat off', 'Repeat all', 'Repeat one'][p.repeat],
                      onPressed: p.cycleRepeat,
                      icon: Icon(
                        p.repeat == 2 ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                        color: p.repeat == 0 ? null : theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
              if (p.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(p.error!, style: TextStyle(color: theme.colorScheme.error)),
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
