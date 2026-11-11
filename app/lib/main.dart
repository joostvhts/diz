import 'package:flutter/widgets.dart';

import 'src/app.dart';
import 'src/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  runApp(DizApp(settings: settings));
}
