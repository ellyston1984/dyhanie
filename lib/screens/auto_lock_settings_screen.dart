import 'package:flutter/material.dart';

import '../services/auto_lock_service.dart';
import '../services/font_service.dart';
import '../services/locale_service.dart';

class AutoLockSettingsScreen extends StatefulWidget {
  const AutoLockSettingsScreen({super.key});

  @override
  State<AutoLockSettingsScreen> createState() => _AutoLockSettingsScreenState();
}

class _AutoLockSettingsScreenState extends State<AutoLockSettingsScreen> {
  final _svc = AutoLockService();
  bool _loading = true;

  double _slider = 5;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _svc.load();
    if (!mounted) return;
    setState(() {
      if (_svc.mode == AutoLockMode.afterTimeout) {
        _slider =
            _svc.timeoutMinutes <= 0 ? 0 : _svc.timeoutMinutes.toDouble();
      } else {
        _slider =
            _svc.timeoutMinutes <= 0 ? 5 : _svc.timeoutMinutes.toDouble();
      }
      _loading = false;
    });
  }

  Future<void> _persist() async {
    await _svc.save();
    if (!mounted) return;
    setState(() {});
  }

  String get _timeoutLabel {
    final v = _slider.round();
    if (v <= 0) return L.t('never');
    if (v == 1) return L.t('minutes_1');
    if (v < 60) return L.tParams('minutes_n', {'n': '$v'});
    final h = v ~/ 60;
    final m = v % 60;
    if (m == 0) {
      return h == 1 ? L.t('hours_1') : L.tParams('hours_n', {'n': '$h'});
    }
    return L.tParams('time_h_m', {'h': '$h', 'm': '$m'});
  }

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final onSurf = Theme.of(context).colorScheme.onSurface;

    if (_loading) {
      return Scaffold(
        backgroundColor: bg,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        title: Text(
          L.t('auto_lock_title'),
          style: FontService.style(fontSize: 18, color: onSurf),
        ),
        iconTheme: IconThemeData(color: onSurf),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SwitchListTile(
            title: Text(
              L.t('enabled'),
              style: FontService.style(color: onSurf),
            ),
            subtitle: Text(
              _svc.summary,
              style: FontService.style(color: onSurf.withValues(alpha: 0.45)),
            ),
            value: _svc.enabled,
            activeThumbColor: onSurf,
            onChanged: (v) async {
              setState(() => _svc.enabled = v);
              await _persist();
            },
          ),
          Divider(color: onSurf.withValues(alpha: 0.12)),
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            child: Text(
              L.t('when_to_lock'),
              style: FontService.style(
                fontSize: 13,
                color: onSurf.withValues(alpha: 0.55),
              ),
            ),
          ),
          RadioGroup<AutoLockMode>(
            groupValue: _svc.mode,
            onChanged: (v) async {
              if (!_svc.enabled || v == null) return;
              setState(() => _svc.mode = v);
              await _persist();
            },
            child: Column(
              children: [
                RadioListTile<AutoLockMode>(
                  value: AutoLockMode.onMinimize,
                  enabled: _svc.enabled,
                  activeColor: onSurf,
                  title: Text(
                    L.t('lock_on_minimize'),
                    style: FontService.style(color: onSurf),
                  ),
                  subtitle: Text(
                    L.t('on_minimize_sub'),
                    style: FontService.style(
                      fontSize: 12,
                      color: onSurf.withValues(alpha: 0.45),
                    ),
                  ),
                ),
                RadioListTile<AutoLockMode>(
                  value: AutoLockMode.afterTimeout,
                  enabled: _svc.enabled,
                  activeColor: onSurf,
                  title: Text(
                    L.t('lock_after_time'),
                    style: FontService.style(color: onSurf),
                  ),
                  subtitle: Text(
                    L.t('after_timeout_sub'),
                    style: FontService.style(
                      fontSize: 12,
                      color: onSurf.withValues(alpha: 0.45),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_svc.enabled && _svc.mode == AutoLockMode.afterTimeout) ...[
            const SizedBox(height: 16),
            Text(
              L.tParams('timeout_label', {'label': _timeoutLabel}),
              style: FontService.style(color: onSurf.withValues(alpha: 0.75)),
            ),
            Slider(
              value: _slider.clamp(0, 120),
              min: 0,
              max: 120,
              divisions: 120,
              activeColor: onSurf,
              inactiveColor: onSurf.withValues(alpha: 0.25),
              label: _timeoutLabel,
              onChanged: (v) {
                setState(() => _slider = v);
              },
              onChangeEnd: (v) async {
                setState(() {
                  _slider = v;
                  _svc.timeoutMinutes = v.round();
                });
                await _persist();
              },
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  L.t('never'),
                  style: FontService.style(
                    fontSize: 11,
                    color: onSurf.withValues(alpha: 0.4),
                  ),
                ),
                Text(
                  L.t('min_1_short'),
                  style: FontService.style(
                    fontSize: 11,
                    color: onSurf.withValues(alpha: 0.4),
                  ),
                ),
                Text(
                  L.t('hours_2_short'),
                  style: FontService.style(
                    fontSize: 11,
                    color: onSurf.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          Text(
            L.t('pin_unlock_hint'),
            style: FontService.style(
              fontSize: 12,
              color: onSurf.withValues(alpha: 0.35),
            ),
          ),
        ],
      ),
    );
  }
}