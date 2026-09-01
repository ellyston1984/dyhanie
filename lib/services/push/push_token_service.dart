import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../dyhanie_api.dart';

class PushTokenService {
  PushTokenService._();
  static final instance = PushTokenService._();

  static const _ch = MethodChannel('su.dyhanie/push_token');

  Future<void> registerWithServer() async {
    String? fcm;
    String? apns;
    try {
      final m = await _ch.invokeMethod<dynamic>('getTokens');
      if (m is Map) {
        fcm = m['fcm']?.toString();
        apns = m['apns']?.toString();
      }
    } catch (e) {
      debugPrint('PushToken: no native ($e)');
      return;
    }
    if ((fcm == null || fcm.isEmpty) && (apns == null || apns.isEmpty)) {
      debugPrint('PushToken: empty token');
      return;
    }
    if (fcm != null && fcm.isNotEmpty) {
      debugPrint('PushToken: got fcm len=${fcm.length}');
    }

    try {
      final api = DyhanieApi.instance;
      if (!api.isConnected) await api.connect();
      await api.request('push.register', payload: {
        if (fcm != null && fcm.isNotEmpty) 'fcm': fcm,
        if (apns != null && apns.isNotEmpty) 'apns': apns,
      });
      debugPrint('PushToken: push.register ok');
    } catch (e) {
      debugPrint('PushToken: push.register failed: $e');
    }
  }
}