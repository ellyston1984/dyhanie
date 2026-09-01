import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/font_service.dart';
import '../services/locale_service.dart';
import '../services/security_service.dart';
import 'home_screen.dart';

class PinLockScreen extends StatefulWidget {
  const PinLockScreen({super.key});

  @override
  State<PinLockScreen> createState() => _PinLockScreenState();
}

class _PinLockScreenState extends State<PinLockScreen> {
  final _ctrl = TextEditingController();
  final _security = SecurityService();
  String? _error;

  Future<void> _unlock() async {
    final pin = _ctrl.text.trim();
    final ok = await _security.checkPin(pin);
    if (!mounted) return;
    if (!ok) {
      setState(() => _error = L.t('pin_wrong'));
      _ctrl.clear();
      return;
    }
    await _security.markUnlocked();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final onSurf = Theme.of(context).colorScheme.onSurface;

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 80),
              Icon(Icons.lock_outline, color: onSurf.withValues(alpha: 0.55), size: 48),
              const SizedBox(height: 20),
              Text(
                L.t('pin_lock'),
                style: FontService.style(fontSize: 24, color: onSurf),
              ),
              const SizedBox(height: 40),
              TextField(
                controller: _ctrl,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 4,
                autofocus: true,
                style: FontService.style(
                  fontSize: 28,
                  letterSpacing: 16,
                  color: onSurf,
                ),
                textAlign: TextAlign.center,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (v) {
                  if (v.length == 4) _unlock();
                },
                decoration: InputDecoration(
                  counterText: '',
                  hintText: '••••',
                  hintStyle: TextStyle(
                    color: onSurf.withValues(alpha: 0.25),
                    letterSpacing: 16,
                  ),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: onSurf.withValues(alpha: 0.25)),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: onSurf),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}