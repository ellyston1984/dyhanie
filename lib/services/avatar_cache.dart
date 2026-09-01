import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'dyhanie_api.dart';

class AvatarCache {
  static String keyFor(String username) =>
      'avatar_${username.toLowerCase().trim()}';

  static String _tsKey(String username) =>
      'avatar_ts_${username.toLowerCase().trim()}';

  static Uint8List? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      var s = raw.trim();
      if (s.contains(',')) s = s.split(',').last.trim();
      s = s.replaceAll(RegExp(r'\s+'), '');
      if (s.isEmpty) return null;
      return base64Decode(s);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(
    String username,
    String base64Data, {
    int? updatedAt,
  }) async {
    final clean = base64Data.contains(',')
        ? base64Data.split(',').last.trim()
        : base64Data.trim();
    if (clean.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final u = username.toLowerCase().trim();
    await prefs.setString(keyFor(u), clean);
    if (updatedAt != null) {
      await prefs.setInt(_tsKey(u), updatedAt);
    } else {
      await prefs.setInt(_tsKey(u), DateTime.now().millisecondsSinceEpoch);
    }
  }

  static Future<void> saveBytes(
    String username,
    Uint8List bytes, {
    int? updatedAt,
  }) async {
    await save(username, base64Encode(bytes), updatedAt: updatedAt);
  }

  static Future<Uint8List?> load(String username) async {
    final prefs = await SharedPreferences.getInstance();
    return _decode(prefs.getString(keyFor(username)));
  }

    static Future<Uint8List?> fetch(
    String username, {
    bool forceNetwork = false,
    String? bindUsername,
  }) async {
    final u = username.toLowerCase().trim();
    if (u.isEmpty) return null;

    final prefs = await SharedPreferences.getInstance();
    final localTs = prefs.getInt(_tsKey(u)) ?? 0;
    final cached = await load(u);

    // Только кэш, если не форсим сеть и кэш есть
    if (!forceNetwork && cached != null && localTs > 0) {
      // всё равно обновим в фоне, но UI получит кэш сейчас
      // ignore: unawaited_futures
      _pullNetwork(u, localTs, bindUsername: bindUsername);
      return cached;
    }

    return _pullNetwork(
      u,
      localTs,
      bindUsername: bindUsername,
      fallback: cached,
    );
  }

  static Future<Uint8List?> _pullNetwork(
    String u,
    int localTs, {
    String? bindUsername,
    Uint8List? fallback,
  }) async {
    try {
      final api = DyhanieApi.instance;
      if (!api.isConnected) {
        await api.connect();
      }
      final bind = bindUsername?.toLowerCase().trim();
      if (bind != null &&
          bind.isNotEmpty &&
          api.boundUsername != bind) {
        try {
          await api.sessionBind(bind);
        } catch (_) {}
      }

      final r = await api.avatarGetWithMeta(u);
      if (r == null) return fallback ?? await load(u);

      final b64 = r['data']?.toString();
      if (b64 == null || b64.isEmpty) return fallback ?? await load(u);

      final remoteTs = r['updated_at'] is int
          ? r['updated_at'] as int
          : int.tryParse('${r['updated_at']}') ?? 0;

      await save(u, b64, updatedAt: remoteTs > 0 ? remoteTs : DateTime.now().millisecondsSinceEpoch);

      final decoded = _decode(b64);
      return decoded ?? fallback;
    } catch (e) {
      // временно можно debugPrint('[avatar] $u $e');
      return fallback ?? await load(u);
    }
  }

  static Future<void> remove(String username) async {
    final prefs = await SharedPreferences.getInstance();
    final u = username.toLowerCase().trim();
    await prefs.remove(keyFor(u));
    await prefs.remove(_tsKey(u));
  }
}