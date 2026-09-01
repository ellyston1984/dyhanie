import 'package:flutter/foundation.dart';

import 'android_vpn_engine.dart';
import 'ios_vpn_engine.dart';
import 'vpn_engine.dart';
import 'web_vpn_engine.dart';

VpnEngine createVpnEngine() {
  if (kIsWeb) return WebVpnEngine();
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return AndroidVpnEngine();
    case TargetPlatform.iOS:
      return IOSVpnEngine();
    default:
      return WebVpnEngine();
  }
}