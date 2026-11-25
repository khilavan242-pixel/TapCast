import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/native.dart';
import 'services/store.dart';
import 'state/cast_controller.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
  ));
  final store = await Store.open();
  final controller = CastController(native: Native(), store: store);
  runApp(TapCastApp(controller: controller));
}

class TapCastApp extends StatelessWidget {
  const TapCastApp({super.key, required this.controller});

  final CastController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => MaterialApp(
        title: 'TapCast',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: controller.themeMode,
        home: Shell(controller: controller),
      ),
    );
  }
}
