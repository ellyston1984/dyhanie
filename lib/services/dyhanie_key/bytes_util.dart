import 'dart:math';
import 'dart:typed_data';

void zeroize(Uint8List? buf) {
  if (buf == null) return;
  for (var i = 0; i < buf.length; i++) {
    buf[i] = 0;
  }
}

bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

Uint8List concat(List<List<int>> parts) {
  var n = 0;
  for (final p in parts) {
    n += p.length;
  }
  final out = Uint8List(n);
  var o = 0;
  for (final p in parts) {
    out.setRange(o, o + p.length, p);
    o += p.length;
  }
  return out;
}

Uint8List randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

int readU16(Uint8List b, int o) => (b[o] << 8) | b[o + 1];

int readU32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

void writeU16(Uint8List b, int o, int v) {
  b[o] = (v >> 8) & 0xff;
  b[o + 1] = v & 0xff;
}

void writeU32(Uint8List b, int o, int v) {
  b[o] = (v >> 24) & 0xff;
  b[o + 1] = (v >> 16) & 0xff;
  b[o + 2] = (v >> 8) & 0xff;
  b[o + 3] = v & 0xff;
}

int compareBytes(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

String hexEncode(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List hexDecode(String hex) {
  final s = hex.trim();
  if (s.length.isOdd) return Uint8List(0);
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
