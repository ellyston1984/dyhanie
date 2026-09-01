import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'bytes_util.dart';
import 'crypto_box.dart';
import 'dyhanie_key_api.dart';
import 'identity.dart';
import 'protocol.dart';

typedef PacketSink = void Function(Uint8List packet);
typedef PlainSink = void Function(Uint8List plaintext);
typedef StateSink = void Function(SessionState state);

class DyhanieSession {
  DyhanieSession({
    required this.peerId,
    required this.local,
    required this.onSend,
    required this.onPlaintext,
    required this.onState,
  });

  final String peerId;
  final DyhanieIdentity local;
  final PacketSink onSend;
  final PlainSink onPlaintext;
  final StateSink onState;

  SessionState state = SessionState.none;
  Uint8List? remotePack;
  String? lastError;

  KeyPair? _eph;
  Uint8List? _ephPub;
  Uint8List? _localNonce;
  Uint8List? _remoteNonce;
  Uint8List? _remoteEph;
  Uint8List? _remoteX;
  Uint8List? _remoteEd;
  bool _gotHandshake = false;
  bool _gotConfirm = false;
  bool _sentConfirm = false;

  Uint8List? _root;
  Uint8List? _ckSend;
  Uint8List? _ckRecv;
  KeyPair? _dhSend;
  Uint8List? _dhSendPub;
  Uint8List? _dhRecvPub;
  int _ns = 0;
  int _nr = 0;
  int _pn = 0;
  bool _needDhRatchet = false;
  final _skipped = <String, Uint8List>{};

  Timer? _timeout;
  Timer? _cover;
  bool _destroyed = false;
  Future<void> _inFlight = Future.value();

  Future<void> start() async {
    if (_destroyed) return;
    _setState(SessionState.handshaking);
    _eph = await x25519New();
    _ephPub = await x25519Public(_eph!);
    _localNonce = randomBytes(32);
    _timeout = Timer(DyhanieProtocol.handshakeTimeout, () {
      fail('handshake_timeout');
    });
    await _sendHandshake();
    if (_gotHandshake) {
      await _tryFinishHandshake();
    }
  }

  Future<void> handlePacket(Uint8List raw) {
    final run = _inFlight.then((_) => _handlePacketLocked(raw));
    _inFlight = run.catchError((_) {});
    return run;
  }

  Future<void> _handlePacketLocked(Uint8List raw) async {
    if (_destroyed || raw.isEmpty) return;
    final type = raw[0];
    final body = raw.sublist(1);
    try {
      if (type == DyhanieProtocol.pktHandshake) {
        await _onHandshake(body);
      } else if (type == DyhanieProtocol.pktConfirm) {
        await _onConfirm(body);
      } else if (type == DyhanieProtocol.pktApp) {
        if (state != SessionState.active && state != SessionState.idle) return;
        await _onApp(body);
      }
    } catch (e) {
      fail('pkt:$e');
    }
  }

  Future<void> sendPlaintext(Uint8List content) async {
    if (_destroyed || state != SessionState.active) return;
    await _sendApp(content, cover: false);
  }

  void touchIdle() {
    if (state == SessionState.idle) {
      _setState(SessionState.active);
    }
  }

  void fail(String reason) {
    lastError = reason;
    destroy();
  }

  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _timeout?.cancel();
    _cover?.cancel();
    _timeout = null;
    _cover = null;
    for (final k in _skipped.values) {
      zeroize(k);
    }
    _skipped.clear();
    zeroize(_root);
    zeroize(_ckSend);
    zeroize(_ckRecv);
    zeroize(_localNonce);
    zeroize(_remoteNonce);
    _setState(SessionState.destroyed);
  }

  void _setState(SessionState s) {
    state = s;
    onState(s);
  }

  Future<void> _sendHandshake() async {
    final msg = concat([
      _u16(DyhanieProtocol.version),
      _u16(DyhanieProtocol.cipherSuite),
      local.x25519Pub,
      local.ed25519Pub,
      _ephPub!,
      _localNonce!,
    ]);
    final sig = await ed25519Sign(local.ed25519, msg);
    _emit(DyhanieProtocol.pktHandshake, concat([msg, sig]));
  }

  Future<void> _onHandshake(Uint8List body) async {
    if (body.length != 196) {
      fail('hs_len');
      return;
    }
    final version = readU16(body, 0);
    final suite = readU16(body, 2);
    if (version != DyhanieProtocol.version ||
        suite != DyhanieProtocol.cipherSuite) {
      fail('hs_downgrade');
      return;
    }
    final rx = body.sublist(4, 36);
    final red = body.sublist(36, 68);
    final reph = body.sublist(68, 100);
    final rnonce = body.sublist(100, 132);
    final sig = body.sublist(132, 196);
    final signed = body.sublist(0, 132);
    final ok = await ed25519Verify(
      publicKey: red,
      message: signed,
      signature: sig,
    );
    if (!ok) {
      fail('hs_sig');
      return;
    }
    if (constantTimeEquals(rx, local.x25519Pub)) {
      fail('hs_self');
      return;
    }
    _remoteX = Uint8List.fromList(rx);
    _remoteEd = Uint8List.fromList(red);
    _remoteEph = Uint8List.fromList(reph);
    _remoteNonce = Uint8List.fromList(rnonce);
    remotePack = concat([_remoteX!, _remoteEd!]);
    _gotHandshake = true;
    await _tryFinishHandshake();
  }

  Future<void> _tryFinishHandshake() async {
    if (!_gotHandshake || _eph == null || _sentConfirm) return;
    final dhIdEph = await x25519Dh(local.x25519, _remoteEph!);
    final dhEphId = await x25519Dh(_eph!, _remoteX!);
    final dhEphEph = await x25519Dh(_eph!, _remoteEph!);
    final iAmAlice = compareBytes(local.pack, remotePack!) <= 0;
    final ikm = iAmAlice
        ? concat([dhIdEph, dhEphId, dhEphEph])
        : concat([dhEphId, dhIdEph, dhEphEph]);
    final root = await hkdf(
      ikm: ikm,
      salt: Uint8List(32),
      info: utf8.encode(DyhanieProtocol.infoHandshakeRoot),
    );
    zeroize(dhIdEph);
    zeroize(dhEphId);
    zeroize(dhEphEph);
    zeroize(ikm);
    _root = root;

    final ids = _sortedIds();
    final confirmMsg = concat([
      utf8.encode(DyhanieProtocol.infoConfirm),
      ids,
      _u16(DyhanieProtocol.version),
    ]);
    final mac = await hmacSha256(root, confirmMsg);
    _emit(DyhanieProtocol.pktConfirm, mac);
    _sentConfirm = true;

    await _initChains(root);
    if (_gotConfirm) {
      _becomeActive();
    }
  }

  Future<void> _onConfirm(Uint8List body) async {
    if (_root == null) {
      // handshake packet may arrive after confirm in parallel; wait
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (_root == null || body.length != 32) {
      fail('confirm');
      return;
    }
    final ids = _sortedIds();
    if (ids.isEmpty) {
      fail('confirm_ids');
      return;
    }
    final confirmMsg = concat([
      utf8.encode(DyhanieProtocol.infoConfirm),
      ids,
      _u16(DyhanieProtocol.version),
    ]);
    final expect = await hmacSha256(_root!, confirmMsg);
    if (!constantTimeEquals(expect, body)) {
      fail('confirm_mac');
      return;
    }
    _gotConfirm = true;
    if (_sentConfirm) {
      _becomeActive();
    }
  }

  Uint8List _sortedIds() {
    final remote = remotePack;
    if (remote == null) return Uint8List(0);
    final localP = local.pack;
    if (compareBytes(localP, remote) <= 0) {
      return concat([localP, remote]);
    }
    return concat([remote, localP]);
  }

  Future<void> _initChains(Uint8List root) async {
    final alice = await hkdf(
      ikm: root,
      salt: Uint8List(32),
      info: utf8.encode(DyhanieProtocol.infoChainAlice),
    );
    final bob = await hkdf(
      ikm: root,
      salt: Uint8List(32),
      info: utf8.encode(DyhanieProtocol.infoChainBob),
    );
    final iAmAlice = compareBytes(local.pack, remotePack!) <= 0;
    _ckSend = iAmAlice ? alice : bob;
    _ckRecv = iAmAlice ? bob : alice;
    _dhSend = _eph;
    _dhSendPub = _ephPub;
    _dhRecvPub = _remoteEph;
    _ns = 0;
    _nr = 0;
    _pn = 0;
  }

  void _becomeActive() {
    _timeout?.cancel();
    _timeout = null;
    _setState(SessionState.active);
    _armCover();
  }

  void _armCover() {
    _cover?.cancel();
    if (_destroyed || state != SessionState.active) return;
    final r = Random.secure();
    final ms = 1500 + r.nextInt(2501);
    _cover = Timer(Duration(milliseconds: ms), () async {
      if (_destroyed || state != SessionState.active) return;
      try {
        await _sendApp(Uint8List(0), cover: true);
      } catch (_) {}
      _armCover();
    });
  }

  Future<void> _sendApp(Uint8List content, {required bool cover}) async {
    if (_ckSend == null) return;
    if (_needDhRatchet) {
      await _dhRatchetSend();
    }
    final step = await _ratchetCk(_ckSend!);
    zeroize(_ckSend);
    _ckSend = step.ck;
    final mk = step.mk;
    final nonce = step.nonce;

    final header = Uint8List(DyhanieProtocol.headerSize);
    writeU16(header, 0, DyhanieProtocol.version);
    writeU16(header, 2, DyhanieProtocol.cipherSuite);
    header.setRange(4, 36, _dhSendPub ?? Uint8List(32));
    writeU32(header, 36, _pn);
    writeU32(header, 40, _ns);
    header.setRange(44, 60, randomBytes(16));
    header[60] = cover ? 1 : 0;
    _ns += 1;

    final inner = _padPlaintext(content, cover: cover);
    final ct = await aeadEncrypt(
      key: mk,
      nonce: nonce,
      plaintext: inner,
      aad: header,
    );
    zeroize(mk);
    zeroize(nonce);
    zeroize(inner);
    await _delayJitter();
    _emit(DyhanieProtocol.pktApp, concat([header, ct]));
    if (!cover) touchIdle();
  }

  Future<void> _onApp(Uint8List body) async {
    if (body.length < DyhanieProtocol.headerSize + DyhanieProtocol.macSize) {
      fail('app_len');
      return;
    }
    final header = body.sublist(0, DyhanieProtocol.headerSize);
    final ct = body.sublist(DyhanieProtocol.headerSize);
    final version = readU16(header, 0);
    final suite = readU16(header, 2);
    if (version != DyhanieProtocol.version ||
        suite != DyhanieProtocol.cipherSuite) {
      fail('app_downgrade');
      return;
    }
    final dhPub = header.sublist(4, 36);
    final n = readU32(header, 40);

    late Uint8List mk;
    late Uint8List nonce;
    if (_dhRecvPub != null && !constantTimeEquals(dhPub, _dhRecvPub!)) {
      await _dhRatchetRecv(dhPub);
    }
    final skipKey = _skipId(dhPub, n);
    if (_skipped.containsKey(skipKey)) {
      final blob = _skipped.remove(skipKey)!;
      mk = blob.sublist(0, 32);
      nonce = blob.sublist(32);
    } else {
      if (n < _nr) {
        fail('replay');
        return;
      }
      if (n - _nr > DyhanieProtocol.maxSkipped) {
        fail('skip_limit');
        return;
      }
      while (_nr < n) {
        final st = await _ratchetCk(_ckRecv!);
        zeroize(_ckRecv);
        _ckRecv = st.ck;
        _skipped[_skipId(dhPub, _nr)] = concat([st.mk, st.nonce]);
        _nr += 1;
        if (_skipped.length > DyhanieProtocol.maxSkipped) {
          fail('skip_limit');
          return;
        }
      }
      final st = await _ratchetCk(_ckRecv!);
      zeroize(_ckRecv);
      _ckRecv = st.ck;
      mk = st.mk;
      nonce = st.nonce;
      _nr += 1;
    }

    final clear = await aeadDecrypt(
      key: mk,
      nonce: nonce,
      cipherAndTag: ct,
      aad: header,
    );
    zeroize(mk);
    zeroize(nonce);
    if (clear == null) {
      fail('mac');
      return;
    }
    if (clear.length < 5) {
      fail('plain_len');
      return;
    }
    final type = clear[0];
    final len = readU32(clear, 1);
    if (type == DyhanieProtocol.contentCover) {
      zeroize(clear);
      return;
    }
    if (type != DyhanieProtocol.contentText ||
        len < 0 ||
        5 + len > clear.length) {
      fail('plain_type');
      return;
    }
    final payload = Uint8List.fromList(clear.sublist(5, 5 + len));
    zeroize(clear);
    touchIdle();
    onPlaintext(payload);
  }

  Future<void> _dhRatchetRecv(Uint8List newDh) async {
    _pn = _ns;
    _ns = 0;
    _nr = 0;
    _dhRecvPub = Uint8List.fromList(newDh);
    final dh = await x25519Dh(_dhSend!, newDh);
    final kdf = await hkdf(
      ikm: concat([_root ?? Uint8List(32), dh]),
      salt: Uint8List(32),
      info: utf8.encode(DyhanieProtocol.infoRoot),
    );
    zeroize(dh);
    zeroize(_root);
    _root = kdf;
    final recv = await hkdf(
      ikm: _root!,
      salt: Uint8List(32),
      info: utf8.encode(DyhanieProtocol.infoCk),
    );
    zeroize(_ckRecv);
    _ckRecv = recv;
    _needDhRatchet = true;
  }

  Future<void> _dhRatchetSend() async {
    _dhSend = await x25519New();
    _dhSendPub = await x25519Public(_dhSend!);
    final dh = await x25519Dh(_dhSend!, _dhRecvPub!);
    final kdf = await hkdf(
      ikm: concat([_root ?? Uint8List(32), dh]),
      salt: Uint8List(32),
      info: utf8.encode(DyhanieProtocol.infoRoot),
    );
    zeroize(dh);
    zeroize(_root);
    _root = kdf;
    final send = await hkdf(
      ikm: _root!,
      salt: Uint8List(32),
      info: utf8.encode(DyhanieProtocol.infoCk),
    );
    zeroize(_ckSend);
    _ckSend = send;
    _ns = 0;
    _needDhRatchet = false;
  }

  Future<({Uint8List ck, Uint8List mk, Uint8List nonce})> _ratchetCk(
    Uint8List ck,
  ) async {
    final okm = await hkdf(
      ikm: ck,
      salt: Uint8List(32),
      info: utf8.encode(DyhanieProtocol.infoMk),
      length: 32 + DyhanieProtocol.nonceSize,
    );
    final nextCk = await hkdf(
      ikm: ck,
      salt: Uint8List(32),
      info: utf8.encode(DyhanieProtocol.infoCk),
    );
    final mk = okm.sublist(0, 32);
    final nonce = okm.sublist(32);
    return (ck: nextCk, mk: mk, nonce: nonce);
  }

  String _skipId(List<int> dh, int n) => '${hexEncode(dh)}:$n';

  Uint8List _padPlaintext(Uint8List content, {required bool cover}) {
    final rawLen = 5 + content.length;
    var basket = DyhanieProtocol.padBaskets.last;
    for (final b in DyhanieProtocol.padBaskets) {
      if (b >= rawLen) {
        basket = b;
        break;
      }
    }
    final out = Uint8List(basket);
    out[0] =
        cover ? DyhanieProtocol.contentCover : DyhanieProtocol.contentText;
    writeU32(out, 1, content.length);
    if (content.isNotEmpty) {
      out.setRange(5, 5 + content.length, content);
    }
    final pad = randomBytes(basket - rawLen);
    if (pad.isNotEmpty) {
      out.setRange(rawLen, basket, pad);
    }
    return out;
  }

  Future<void> _delayJitter() async {
    final ms = 20 + Random.secure().nextInt(161);
    await Future<void>.delayed(Duration(milliseconds: ms));
  }

  void _emit(int type, Uint8List body) {
    if (_destroyed) return;
    onSend(concat([
      Uint8List.fromList([type]),
      body,
    ]));
  }

  Uint8List _u16(int v) {
    final b = Uint8List(2);
    writeU16(b, 0, v);
    return b;
  }
}
