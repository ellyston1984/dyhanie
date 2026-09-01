import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'bytes_util.dart';
import 'crypto_box.dart';
import 'mnemonic.dart';
import 'protocol.dart';

class DyhanieIdentity {
  DyhanieIdentity({
    required this.seed,
    required this.x25519,
    required this.ed25519,
    required this.x25519Pub,
    required this.ed25519Pub,
  });

  final Uint8List seed;
  final SimpleKeyPair x25519;
  final SimpleKeyPair ed25519;
  final Uint8List x25519Pub;
  final Uint8List ed25519Pub;

  Uint8List get pack => concat([x25519Pub, ed25519Pub]);

  static const _seedKey = 'dyhanie_identity_seed';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static Future<DyhanieIdentity> fromSeed(Uint8List seed) async {
    if (seed.length != 32) {
      throw ArgumentError('seed must be 32 bytes');
    }
    final xSeed = await hkdf(
      ikm: seed,
      salt: Uint8List(32),
      info: utf8.encode(DyhanieProtocol.infoX25519),
    );
    final eSeed = await hkdf(
      ikm: seed,
      salt: Uint8List(32),
      info: utf8.encode(DyhanieProtocol.infoEd25519),
    );
    final x = await x25519FromSeed(xSeed);
    final e = await ed25519FromSeed(eSeed);
    final xp = await x25519Public(x);
    final ep = await ed25519Public(e);
    zeroize(xSeed);
    zeroize(eSeed);
    return DyhanieIdentity(
      seed: seed,
      x25519: x,
      ed25519: e,
      x25519Pub: xp,
      ed25519Pub: ep,
    );
  }

  static Future<({DyhanieIdentity identity, List<String> words})>
      generateNew() async {
    final words = await DyhanieMnemonic.generate();
    final identity = await fromPhrase(words);
    return (identity: identity, words: words);
  }

  static Future<DyhanieIdentity> fromPhrase(List<String> words) async {
    final entropy = await DyhanieMnemonic.parse(words);
    if (entropy == null) {
      throw StateError('invalid phrase');
    }
    final seed = await hkdf(
      ikm: entropy,
      salt: Uint8List(32),
      info: utf8.encode(DyhanieProtocol.infoIdentitySeed),
    );
    zeroize(entropy);
    return fromSeed(seed);
  }

  static Future<DyhanieIdentity?> load() async {
    try {
      final hex = await _storage.read(key: _seedKey);
      if (hex == null || hex.isEmpty) return null;
      final seed = hexDecode(hex);
      if (seed.length != 32) return null;
      return fromSeed(seed);
    } catch (_) {
      return null;
    }
  }

  Future<void> persist() async {
    await _storage.write(key: _seedKey, value: hexEncode(seed));
  }

  static Future<void> wipe() async {
    try {
      await _storage.delete(key: _seedKey);
    } catch (_) {}
  }

  /// 60 decimal digits from SHA-256 of both packed identities (sorted).
  static Future<String> safetyNumber({
    required Uint8List localPack,
    required Uint8List remotePack,
  }) async {
    final first =
        compareBytes(localPack, remotePack) <= 0 ? localPack : remotePack;
    final second =
        compareBytes(localPack, remotePack) <= 0 ? remotePack : localPack;
    final h = await sha256(concat([first, second]));
    final sb = StringBuffer();
    for (final byte in h) {
      sb.write(byte.toString().padLeft(3, '0'));
    }
    var s = sb.toString();
    if (s.length < 60) {
      s = s.padRight(60, '0');
    }
    return s.substring(0, 60);
  }
}
