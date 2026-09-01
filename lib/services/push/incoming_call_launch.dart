import 'package:flutter/services.dart';

class IncomingCallLaunch {
  IncomingCallLaunch._();
  static final instance = IncomingCallLaunch._();

  static const _ch = MethodChannel('su.dyhanie/incoming_call_launch');

  Future<Map<String, dynamic>?> take() async {
    try {
      final m = await _ch.invokeMethod<dynamic>('takeLaunch');
      if (m is! Map) return null;
      return Map<String, dynamic>.from(m);
    } catch (_) {
      return null;
    }
  }

  bool isAccept(Map<String, dynamic> m) => m['accepted'] == true;

  bool isDecline(Map<String, dynamic> m) => m['declined'] == true;
}