import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'bytes_util.dart';
import 'protocol.dart';

final _sha256 = Sha256();
final _hmac = Hmac.sha256();
final _x25519 = X25519();
final _ed25519 = Ed25519();
final _aead = Chacha20.poly1305Aead();

Future<Uint8List> sha256(List<int> data) async {
  final h = await _sha256.hash(data);
  return Uint8List.fromList(h.bytes);
}

Future<Uint8List> hmacSha256(List<int> key, List<int> data) async {
  final mac = await _hmac.calculateMac(data, secretKey: SecretKey(key));
  return Uint8List.fromList(mac.bytes);
}

Future<Uint8List> hkdf({
  required List<int> ikm,
  required List<int> salt,
  required List<int> info,
  int length = 32,
}) async {
  final hk = Hkdf(hmac: Hmac.sha256(), outputLength: length);
  final key = await hk.deriveKey(
    secretKey: SecretKey(ikm),
    nonce: salt,
    info: info,
  );
  return Uint8List.fromList(await key.extractBytes());
}

Future<SimpleKeyPair> x25519FromSeed(List<int> seed32) {
  return _x25519.newKeyPairFromSeed(seed32);
}

Future<SimpleKeyPair> ed25519FromSeed(List<int> seed32) {
  return _ed25519.newKeyPairFromSeed(seed32);
}

Future<KeyPair> x25519New() => _x25519.newKeyPair();

Future<Uint8List> x25519Public(KeyPair kp) async {
  final p = await kp.extractPublicKey();
  if (p is! SimplePublicKey) {
    throw StateError('x25519 public key');
  }
  return Uint8List.fromList(p.bytes);
}

Future<Uint8List> ed25519Public(KeyPair kp) async {
  final p = await kp.extractPublicKey();
  if (p is! SimplePublicKey) {
    throw StateError('ed25519 public key');
  }
  return Uint8List.fromList(p.bytes);
}

Future<Uint8List> x25519Dh(KeyPair local, List<int> remotePub) async {
  final secret = await _x25519.sharedSecretKey(
    keyPair: local,
    remotePublicKey: SimplePublicKey(remotePub, type: KeyPairType.x25519),
  );
  return Uint8List.fromList(await secret.extractBytes());
}

Future<Uint8List> ed25519Sign(KeyPair kp, List<int> message) async {
  final sig = await _ed25519.sign(message, keyPair: kp);
  return Uint8List.fromList(sig.bytes);
}

Future<bool> ed25519Verify({
  required List<int> publicKey,
  required List<int> message,
  required List<int> signature,
}) async {
  return _ed25519.verify(
    message,
    signature: Signature(
      signature,
      publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
    ),
  );
}

Future<Uint8List> aeadEncrypt({
  required List<int> key,
  required List<int> nonce,
  required List<int> plaintext,
  required List<int> aad,
}) async {
  final box = await _aead.encrypt(
    plaintext,
    secretKey: SecretKey(key),
    nonce: nonce,
    aad: aad,
  );
  return concat([box.cipherText, box.mac.bytes]);
}

Future<Uint8List?> aeadDecrypt({
  required List<int> key,
  required List<int> nonce,
  required List<int> cipherAndTag,
  required List<int> aad,
}) async {
  if (cipherAndTag.length < DyhanieProtocol.macSize) return null;
  final split = cipherAndTag.length - DyhanieProtocol.macSize;
  try {
    final clear = await _aead.decrypt(
      SecretBox(
        cipherAndTag.sublist(0, split),
        nonce: nonce,
        mac: Mac(cipherAndTag.sublist(split)),
      ),
      secretKey: SecretKey(key),
      aad: aad,
    );
    return Uint8List.fromList(clear);
  } catch (_) {
    return null;
  }
}
