import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../dyhanie_api.dart';

class PushTokenService {
  PushTokenService._();
  static final instance = PushTokenService._();

  static const _ch = MethodChannel('su.dyhanie/push_token');

  Future<void> registerWithServer() async {
    String? fcm;
<<<<<<< HEAD
    String? apns;
=======
>>>>>>> f1159a9 (Push, incoming call launch, locale, avatar cache, related lib updates)
    try {
      final m = await _ch.invokeMethod<dynamic>('getTokens');
      if (m is Map) {
        fcm = m['fcm']?.toString();
<<<<<<< HEAD
        apns = m['apns']?.toString();
=======
>>>>>>> f1159a9 (Push, incoming call launch, locale, avatar cache, related lib updates)
      }
    } catch (e) {
      debugPrint('PushToken: no native ($e)');
      return;
    }
<<<<<<< HEAD
    if ((fcm == null || fcm.isEmpty) && (apns == null || apns.isEmpty)) return;
=======
    if (fcm == null || fcm.isEmpty) {
      debugPrint('PushToken: empty token');
      return;
    }
    debugPrint('PushToken: got fcm len=${fcm.length}');
>>>>>>> f1159a9 (Push, incoming call launch, locale, avatar cache, related lib updates)

    try {
      final api = DyhanieApi.instance;
      if (!api.isConnected) await api.connect();
<<<<<<< HEAD
      await api.request('push.register', payload: {
        if (fcm != null && fcm.isNotEmpty) 'fcm': fcm,
        if (apns != null && apns.isNotEmpty) 'apns': apns,
      });
    } catch (e) {
      debugPrint('push.register: $e');
=======
      await api.request('push.register', payload: {'fcm': fcm});
      debugPrint('PushToken: push.register ok');
    } catch (e) {
      debugPrint('PushToken: push.register failed: $e');
>>>>>>> f1159a9 (Push, incoming call launch, locale, avatar cache, related lib updates)
    }
  }
}