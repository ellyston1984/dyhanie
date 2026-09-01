import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/dyhanie_api.dart';
import '../services/font_service.dart';
import '../services/locale_service.dart';
import '../services/security_service.dart';
import 'create_profile_screen.dart';
import 'home_screen.dart';
import 'pin_lock_screen.dart';
import 'welcome_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  final _security = SecurityService();

  @override
  void initState() {
    super.initState();
    _go();
  }

  /// Подключение к VPS; ошибка сети не блокирует вход в приложение.
  Future<void> _bindIfNeeded(String username) async {
    try {
      await DyhanieApi.instance.connect();
      await DyhanieApi.instance.sessionBind(username);
      debugPrint('Dyhanie bound as $username');
    } catch (e) {
      debugPrint('Dyhanie bind failed: $e');
    }
  }

  Future<void> _go() async {
    await Future.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;

    final pinSet = await _security.isPinSet();
    if (!mounted) return;

    if (!pinSet) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const WelcomeScreen()),
      );
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('username');

    // Сессия на VPS, если профиль уже есть (до PIN и до Home)
    if (username != null && username.isNotEmpty) {
      await _bindIfNeeded(username);
      if (!mounted) return;
    }

    final needLock = await _security.needsLockScreen();
    if (!mounted) return;
    if (needLock) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const PinLockScreen()),
      );
      return;
    }

    if (username == null || username.isEmpty) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const CreateProfileScreen()),
      );
    } else {
      await _security.markActive();
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final onSurf = Theme.of(context).colorScheme.onSurface;

    return Scaffold(
      backgroundColor: bg,
      body: Center(
        child: Text(
          L.t('app_name'),
          style: FontService.style(
            fontSize: 36,
            fontWeight: FontWeight.w300,
            color: onSurf,
          ),
        ),
      ),
    );
  }
}