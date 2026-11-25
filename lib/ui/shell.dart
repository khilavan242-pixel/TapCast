import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/cast_controller.dart';
import 'browser_page.dart';
import 'devices_sheet.dart';
import 'files_page.dart';
import 'recent_page.dart';
import 'remote_sheet.dart';
import 'settings_page.dart';

enum _Page { browser, files, recent, settings }

/// The main screen: a menu, the pages, and a small remote while something plays on the TV.
class Shell extends StatefulWidget {
  const Shell({super.key, required this.controller});

  final CastController controller;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  final GlobalKey<ScaffoldState> _scaffold = GlobalKey<ScaffoldState>();
  final GlobalKey<BrowserPageState> _browser = GlobalKey<BrowserPageState>();
  _Page _page = _Page.browser;

  CastController get c => widget.controller;

  static const _titles = {
    _Page.browser: 'Browser',
    _Page.files: 'Phone files',
    _Page.recent: 'Recent',
    _Page.settings: 'Settings',
  };

  void _go(_Page p) {
    Navigator.of(context).maybePop(); // close the drawer
    setState(() => _page = p);
  }

  Future<void> _onBack() async {
    if (_page != _Page.browser) {
      setState(() => _page = _Page.browser);
      return;
    }
    if (await (_browser.currentState?.goBack() ?? Future.value(false))) return;
    // Leaving the screen does not stop the cast: the phone keeps the TV going from the notification.
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final message = c.takeMessage();
        if (message != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(content: Text(message)));
          });
        }
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _onBack();
          },
          child: Scaffold(
            key: _scaffold,
            drawer: _drawer(theme),
            body: SafeArea(
              child: Column(
                children: [
                  if (_page != _Page.browser)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 4, 16, 4),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: () => _scaffold.currentState?.openDrawer(),
                            icon: const Icon(Icons.menu_rounded),
                          ),
                          Text(_titles[_page]!, style: theme.textTheme.titleLarge),
                        ],
                      ),
                    ),
                  Expanded(
                    child: IndexedStack(
                      index: _page.index,
                      children: [
                        BrowserPage(
                          key: _browser,
                          controller: c,
                          onMenu: () => _scaffold.currentState?.openDrawer(),
                          onCast: () => showDevicesSheet(context, c),
                        ),
                        FilesPage(controller: c),
                        RecentPage(controller: c),
                        SettingsPage(controller: c),
                      ],
                    ),
                  ),
                  if (c.cast.active) _miniRemote(theme),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _miniRemote(ThemeData theme) {
    final s = c.cast;
    final thumb = thumbFor(s.uri);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => showRemote(context, c),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 64,
                  height: 36,
                  child: thumb == null
                      ? const ColoredBox(color: Colors.black26, child: Icon(Icons.tv_rounded))
                      : Image.network(thumb, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black26)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.title?.isNotEmpty == true ? s.title! : 'Casting',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text('on ${s.device}', style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => c.control(s.paused ? 'resume' : 'pause'),
                icon: Icon(s.paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
              ),
              IconButton(onPressed: () => c.control('next'), icon: const Icon(Icons.skip_next_rounded)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _drawer(ThemeData theme) {
    Widget item(_Page p, IconData icon, String label) => ListTile(
          leading: Icon(icon),
          title: Text(label),
          selected: _page == p,
          onTap: () => _go(p),
        );
    return Drawer(
      child: SafeArea(
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Row(
                children: [
                  Icon(Icons.cast_connected_rounded, size: 32, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Text('TapCast', style: theme.textTheme.headlineSmall),
                ],
              ),
            ),
            item(_Page.browser, Icons.language_rounded, 'Browser'),
            item(_Page.files, Icons.folder_rounded, 'Phone files'),
            item(_Page.recent, Icons.history_rounded, 'Recent'),
            const Divider(),
            item(_Page.settings, Icons.settings_rounded, 'Settings'),
          ],
        ),
      ),
    );
  }
}
