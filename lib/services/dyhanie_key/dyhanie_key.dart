import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'dyhanie_key_api.dart';
import 'identity.dart';
import 'mnemonic.dart';
import 'session.dart';

class DyhanieKey implements DyhanieKeyApi {
  DyhanieKey._();
  static final DyhanieKey instance = DyhanieKey._();

  DyhanieIdentity? _identity;
  final _sessions = <String, DyhanieSession>{};

  DyhanieIdentity? get identity => _identity;
  bool get hasIdentity => _identity != null;

  Future<void> init() async {
    _identity = await DyhanieIdentity.load();
  }

  @override
  Future<List<String>> generateRecoveryPhrase() async {
    for (final s in _sessions.values) {
      s.destroy();
    }
    _sessions.clear();
    await DyhanieIdentity.wipe();
    final made = await DyhanieIdentity.generateNew();
    _identity = made.identity;
    await _identity!.persist();
    return made.words;
  }

  @override
  Future<bool> restoreFromPhrase(List<String> words) async {
    try {
      final identity = await DyhanieIdentity.fromPhrase(words);
      for (final s in _sessions.values) {
        s.destroy();
      }
      _sessions.clear();
      await DyhanieIdentity.wipe();
      _identity = identity;
      await identity.persist();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String> safetyNumber({
    required String localId,
    required String remoteId,
  }) async {
    final local = _identity;
    if (local == null) {
      return List.filled(60, '0').join();
    }
    final prefs = await SharedPreferences.getInstance();
    final hex = prefs.getString(_tofuKey(remoteId));
    if (hex == null || hex.isEmpty) {
      return await DyhanieIdentity.safetyNumber(
        localPack: local.pack,
        remotePack: Uint8List.fromList(remoteId.codeUnits),
      );
    }
    return await DyhanieIdentity.safetyNumber(
      localPack: local.pack,
      remotePack: await _packFromHex(hex),
    );
  }

  Future<String> safetyNumberForPack(Uint8List remotePack) async {
    final local = _identity;
    if (local == null) return List.filled(60, '0').join();
    return DyhanieIdentity.safetyNumber(
      localPack: local.pack,
      remotePack: remotePack,
    );
  }

  @override
  Future<SessionState> currentSessionState(String peerId) async {
    return _sessions[peerId.toLowerCase()]?.state ?? SessionState.none;
  }

  @override
  Future<void> destroySession(String peerId) async {
    final s = _sessions.remove(peerId.toLowerCase());
    s?.destroy();
  }

  @override
  Future<SessionState> simulateHandshake(String peerId) async {
    return currentSessionState(peerId);
  }

  DyhanieSession? sessionFor(String peerId) =>
      _sessions[peerId.toLowerCase().trim()];

  DyhanieSession attachSession({
    required String peerId,
    required PacketSink onSend,
    required PlainSink onPlaintext,
    required StateSink onState,
  }) {
    final id = peerId.toLowerCase().trim();
    _sessions[id]?.destroy();
    final ident = _identity;
    if (ident == null) {
      throw StateError('no identity');
    }
    final session = DyhanieSession(
      peerId: id,
      local: ident,
      onSend: onSend,
      onPlaintext: onPlaintext,
      onState: onState,
    );
    _sessions[id] = session;
    return session;
  }

  Future<TofuCheck> rememberPeer(String peerId, Uint8List pack) async {
    final id = peerId.toLowerCase().trim();
    final prefs = await SharedPreferences.getInstance();
    final key = _tofuKey(id);
    final prev = prefs.getString(key);
    final hex = _toHex(pack);
    if (prev == null || prev.isEmpty) {
      await prefs.setString(key, hex);
      return TofuCheck.first;
    }
    if (prev.toLowerCase() == hex.toLowerCase()) {
      return TofuCheck.known;
    }
    return TofuCheck.changed;
  }

  static String _tofuKey(String peerId) =>
      'dyhanie_tofu_${peerId.toLowerCase().trim()}';

  static String _toHex(Uint8List b) {
    final sb = StringBuffer();
    for (final x in b) {
      sb.write(x.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static Future<Uint8List> _packFromHex(String hex) async {
    final s = hex.trim();
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

enum TofuCheck { first, known, changed }

/// Точка доступа для UI и P2P.
DyhanieKeyApi get dyhanieKey => DyhanieKey.instance;

int get dyhaniePhraseWordCount => DyhanieMnemonic.wordCount;
