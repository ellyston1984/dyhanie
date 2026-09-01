import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'screens/splash_screen.dart';
import 'services/font_controller.dart';
import 'services/font_service.dart';
import 'services/icon_style_controller.dart';
import 'services/incoming_call_service.dart';
import 'services/locale_controller.dart';
import 'services/locale_service.dart';
import 'services/theme_controller.dart';
import 'services/theme_service.dart';
import 'services/webrtc_ice.dart';
import 'services/shorebird_update_service.dart';
import 'services/transport_mode_service.dart';
import 'services/dyhanie_key/dyhanie_key.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await LocaleController.instance.init();
  await FontController.instance.init();
  await IconStyleController.instance.init();
  await ThemeController.instance.init();
  await WebRtcIce.load();
  await TransportModeService.instance.init();
  try {
    await DyhanieKey.instance.init();
  } catch (e) {
    debugPrint('[dyhaniekey] init failed: $e');
  }

  if (!kIsWeb) {
    try {
      await ShorebirdUpdateService.instance.checkAndDownload(force: true);
    } catch (e) {
      debugPrint('[shorebird] startup check failed: $e');
    }
  }

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ThemeController.instance.refreshAuto();
      if (!kIsWeb) {
        ShorebirdUpdateService.instance.checkAndDownload(force: true);
      }
    }
  }

  ThemeData _buildTheme(ThemeData base) {
    return base.copyWith(
      textTheme: FontService.applyTo(base.textTheme),
      primaryTextTheme: FontService.applyTo(base.primaryTextTheme),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        LocaleController.instance,
        FontController.instance,
        IconStyleController.instance,
        ThemeController.instance,
      ]),
      builder: (context, _) {
        final localeCode = LocaleController.instance.code;
        final fontCode = FontController.instance.code;
        final iconCode = IconStyleController.instance.code;
        final themeCode = ThemeController.instance.code;
        final isDark = ThemeService.resolvedIsDark();

        final light = _buildTheme(ThemeService.lightTheme());
        final dark = _buildTheme(ThemeService.darkTheme());

        return MaterialApp(
          key: ValueKey('app_${localeCode}_${fontCode}_${iconCode}_$themeCode'),
          navigatorKey: appNavigatorKey,
          debugShowCheckedModeBanner: false,
          title: L.t('app_name'),
          theme: light,
          darkTheme: dark,
          themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
          locale: Locale(localeCode.split('_').first),
          home: const SplashScreen(),
        );
      },
    );
  }
}