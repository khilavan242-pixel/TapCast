import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/cast_controller.dart';
import 'browser_page.dart';
import 'bookmarks_page.dart';
import 'devices_sheet.dart';
import 'files_page.dart';
import 'recent_page.dart';
import 'floating_mini.dart';
import 'settings_page.dart';

enum _Page { browser, bookmarks, files, recent, settings }

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
    _Page.bookmarks: 'Bookmarks',
    _Page.files: 'Phone files',
    _Page.recent: 'Recent',
    _Page.settings: 'Settings',
  };

  void _go(_Page p) {
    _scaffold.currentState?.closeDrawer();
    setState(() => _page = p);
  }

  void _openUrl(String url) {
    _go(_Page.browser);
    _browser.currentState?.open(url);
  }

  Future<void> _onBack() async {
    if (_scaffold.currentState?.isDrawerOpen ?? false) {
      _scaffold.currentState?.closeDrawer();
      return;
    }
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
              child: Stack(
                children: [
                  Column(
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
                        BookmarksPage(controller: c, onOpen: _openUrl),
                        FilesPage(controller: c),
                        RecentPage(controller: c),
                        SettingsPage(controller: c),
                      ],
                    ),
                  ),
                ],
              ),
                  Positioned.fill(child: FloatingMini(controller: c)),
                ],
              ),
            ),
          ),
        );
      },
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
            item(_Page.bookmarks, Icons.bookmark_rounded, 'Bookmarks'),
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
