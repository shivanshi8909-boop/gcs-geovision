import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme/app_theme.dart';
import 'services/auth_service.dart';
import 'services/db_service.dart';
import 'services/api_service.dart';
import 'services/websocket_service.dart';
import 'services/face_server_service.dart';
import 'router/app_router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db = DbService();
  await db.seedDefaults();

  final prefs = await SharedPreferences.getInstance();
  final isDark = prefs.getBool('gv_theme_dark') ?? true;

  final auth = AuthService();
  await auth.restoreSession();

  final apiService  = ApiService();
  final wsService   = WebSocketService();
  final faceService = FaceServerService();

  // Inject token if session was already restored
  if (auth.token != null) {
    apiService.setToken(auth.token);
    wsService.setToken(auth.token!);
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => ThemeNotifier()..setDark(isDark),
        ),
        ChangeNotifierProvider<AuthService>.value(value: auth),
        Provider<ApiService>(
          create: (_) => apiService,
          dispose: (_, s) => s.dispose(),
        ),
        ChangeNotifierProvider<WebSocketService>(
          create: (_) => wsService,
        ),
        ChangeNotifierProvider<FaceServerService>.value(
          value: faceService,
        ),
      ],
      child: const GeoVisionApp(),
    ),
  );
}

class GeoVisionApp extends StatefulWidget {
  const GeoVisionApp({super.key});

  @override
  State<GeoVisionApp> createState() => _GeoVisionAppState();
}

class _GeoVisionAppState extends State<GeoVisionApp> {
  late final dynamic _router;

  @override
  void initState() {
    super.initState();

    final auth = context.read<AuthService>();
    _router = buildRouter(auth);

    auth.addListener(() {
      _router.refresh();

      final api = context.read<ApiService>();
      final ws  = context.read<WebSocketService>();

      if (auth.token != null) {
        api.setToken(auth.token);
        ws.setToken(auth.token!);
      } else {
        api.setToken(null);
        ws.disconnect();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<ThemeNotifier>().isDark;

    SharedPreferences.getInstance()
        .then((p) => p.setBool('gv_theme_dark', isDark));

    return MaterialApp.router(
      title: 'GeoVision Campus Security',
      debugShowCheckedModeBanner: false,
      theme:     buildTheme(dark: false),
      darkTheme: buildTheme(dark: true),
      themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
      routerConfig: _router,
    );
  }
}