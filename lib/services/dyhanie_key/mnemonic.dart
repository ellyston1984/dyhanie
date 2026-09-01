import 'dart:math';
import 'dart:typed_data';

import 'bip39_english.dart';
import 'crypto_box.dart';
import 'protocol.dart';

/// BIP-39 mnemonic with 64 bits of entropy → exactly 6 words.
class DyhanieMnemonic {
  static const wordCount = DyhanieProtocol.wordCount;

  static Future<List<String>> generate() async {
    final entropy = Uint8List(DyhanieProtocol.entropyBytes);
    final r = Random.secure();
    for (var i = 0; i < entropy.length; i++) {
      entropy[i] = r.nextInt(256);
    }
    return fromEntropy(entropy);
  }

  static Future<List<String>> fromEntropy(Uint8List entropy) async {
    if (entropy.length != DyhanieProtocol.entropyBytes) {
      throw ArgumentError('entropy must be 8 bytes');
    }
    final hash = await sha256(entropy);
    final checksum = hash[0] >> 6; // 2 bits
    final bits = _toBits(entropy);
    bits.addAll(_intBits(checksum, 2));
    final words = <String>[];
    for (var i = 0; i < wordCount; i++) {
      var idx = 0;
      for (var b = 0; b < 11; b++) {
        idx = (idx << 1) | bits[i * 11 + b];
      }
      words.add(bip39English[idx]);
    }
    return words;
  }

  /// Returns 8-byte entropy if the phrase is a valid 6-word mnemonic.
  static Future<Uint8List?> parse(List<String> words) async {
    final cleaned = words
        .map((w) => w.trim().toLowerCase())
        .where((w) => w.isNotEmpty)
        .toList();
    if (cleaned.length != wordCount) return null;
    final bits = <int>[];
    for (final w in cleaned) {
      final idx = bip39English.indexOf(w);
      if (idx < 0) return null;
      bits.addAll(_intBits(idx, 11));
    }
    if (bits.length != 66) return null;
    final entropy = _fromBits(bits.sublist(0, 64));
    final got = bits[64] << 1 | bits[65];
    final hash = await sha256(entropy);
    final expect = hash[0] >> 6;
    if (got != expect) return null;
    return entropy;
  }

  static List<int> _toBits(Uint8List bytes) {
    final bits = <int>[];
    for (final b in bytes) {
      for (var i = 7; i >= 0; i--) {
        bits.add((b >> i) & 1);
      }
    }
    return bits;
  }

  static List<int> _intBits(int value, int n) {
    final bits = <int>[];
    for (var i = n - 1; i >= 0; i--) {
      bits.add((value >> i) & 1);
    }
    return bits;
  }

  static Uint8List _fromBits(List<int> bits) {
    final out = Uint8List(bits.length ~/ 8);
    for (var i = 0; i < out.length; i++) {
      var v = 0;
      for (var b = 0; b < 8; b++) {
        v = (v << 1) | bits[i * 8 + b];
      }
      out[i] = v;
    }
    return out;
  }
}
