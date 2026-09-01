import 'package:shared_preferences/shared_preferences.dart';

/// ICE / TURN — часть P2P-туннеля.
/// Не связан с [blockServerMessages] (тот флаг только про relay сообщений).
class WebRtcIce {
  WebRtcIce._();

  static const _kTurnUrls = 'webrtc_turn_urls';
  static const _kTurnUser = 'webrtc_turn_user';
  static const _kTurnPass = 'webrtc_turn_pass';
  static const _kStunUrls = 'webrtc_stun_urls';
  static const _kForceRelay = 'webrtc_force_relay';

  /// Заводские значения (можно сменить в настройках ICE).
  static const String defaultStun =
      'stun:77.91.113.69:3478\nstun:stun.l.google.com:19302';

  static const String defaultTurn =
      'turn:77.91.113.69:3478?transport=udp\n'
      'turn:77.91.113.69:3478?transport=tcp';

  static const String defaultTurnUser = 'dyhanie';
  static const String defaultTurnPass = '';

  static String turnUrls = defaultTurn;
  static String turnUser = defaultTurnUser;
  static String turnPass = defaultTurnPass;
  static String stunUrls = defaultStun;
  static bool forceRelayOnly = false;

  /// Читает настройки с диска; пустые → заводские.
  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();

    final turn = p.getString(_kTurnUrls);
    turnUrls =
        (turn == null || turn.trim().isEmpty) ? defaultTurn : turn.trim();

    final user = p.getString(_kTurnUser);
    turnUser =
        (user == null || user.trim().isEmpty) ? defaultTurnUser : user.trim();

    final pass = p.getString(_kTurnPass);
    turnPass =
        (pass == null || pass.isEmpty) ? defaultTurnPass : pass;

    final stun = p.getString(_kStunUrls);
    stunUrls =
        (stun == null || stun.trim().isEmpty) ? defaultStun : stun.trim();

    forceRelayOnly = p.getBool(_kForceRelay) ?? false;
  }

  /// Пишет настройки и обновляет static-поля.
  static Future<void> save({
    required String turn,
    required String user,
    required String pass,
    required String stun,
    required bool forceRelay,
  }) async {
    final p = await SharedPreferences.getInstance();
    final stunVal = stun.trim().isEmpty ? defaultStun : stun.trim();
    final turnVal = turn.trim().isEmpty ? defaultTurn : turn.trim();
    final userVal = user.trim().isEmpty ? defaultTurnUser : user.trim();
    final passVal = pass.isEmpty ? defaultTurnPass : pass;

    await p.setString(_kTurnUrls, turnVal);
    await p.setString(_kTurnUser, userVal);
    await p.setString(_kTurnPass, passVal);
    await p.setString(_kStunUrls, stunVal);
    await p.setBool(_kForceRelay, forceRelay);

    turnUrls = turnVal;
    turnUser = userVal;
    turnPass = passVal;
    stunUrls = stunVal;
    forceRelayOnly = forceRelay;
  }

  /// Сброс к заводским.
  static Future<void> resetToDefaults() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kTurnUrls);
    await p.remove(_kTurnUser);
    await p.remove(_kTurnPass);
    await p.remove(_kStunUrls);
    await p.remove(_kForceRelay);
    await load();
  }

  /// Конфиг для [createPeerConnection] — чат (P2P) и звонки.
  static Map<String, dynamic> get config {
    final servers = <Map<String, dynamic>>[];

    for (final u in _splitUrls(stunUrls)) {
      servers.add({'urls': u});
    }
    if (servers.isEmpty) {
      servers.add({'urls': defaultStun});
    }

    for (final u in _splitUrls(turnUrls)) {
      final entry = <String, dynamic>{'urls': u};
      if (turnUser.isNotEmpty) entry['username'] = turnUser;
      if (turnPass.isNotEmpty) entry['credential'] = turnPass;
      servers.add(entry);
    }

    final map = <String, dynamic>{
      'iceServers': servers,
      'iceCandidatePoolSize': 4,
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    };

    if (forceRelayOnly) {
      map['iceTransportPolicy'] = 'relay';
    }

    return map;
  }

  static List<String> _splitUrls(String raw) {
    return raw
        .split(RegExp(r'[\n,]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }
}