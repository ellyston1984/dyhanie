import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'dyhanie_api.dart';
import 'dyhanie_key/dyhanie_key.dart';
import 'dyhanie_key/dyhanie_key_api.dart';
import 'dyhanie_key/session.dart';
import 'webrtc_ice.dart';

/// WebRTC DataChannel P2P для 1:1 чата.
///
/// Правки относительно старой версии:
/// - usernames всегда в lowercase при сравнении signal
/// - «открыт» только когда DataChannel реально Open (не только ICE)
/// - аккуратнее re-offer (не спамим, если remote уже set / идёт answer)
/// - polite/impolite glare: младший username = offerer (impolite), старший = polite
/// - backoff reconnect-сигнала need_restart без лишних offer-раундов
class P2PService {
  final String roomCode;
  final String username;
  final String otherUser;

  late final String _me;
  late final String _peer;

  RTCPeerConnection? _pc;
  RTCDataChannel? _channel;

  final _messageController = StreamController<String>.broadcast();
  Stream<String> get messages => _messageController.stream;

  final _statusController = StreamController<String>.broadcast();
  Stream<String> get status => _statusController.stream;

  StreamSubscription? _signalSub;
  Timer? _reofferTimer;
  Timer? _openTimeout;
  DyhanieSession? _crypto;

  /// Младший username по compareTo — offerer (impolite).
  bool _isOfferer = false;

  bool _closed = false;
  bool _remoteSet = false;
  bool _opened = false;
  bool _offerHandled = false;
  bool _makingOffer = false;
  int _offerRound = 0;

  final List<RTCIceCandidate> _pendingCandidates = [];

  static const _reofferDelays = <Duration>[
    Duration(seconds: 3),
    Duration(seconds: 7),
  ];

  static const _openTimeoutDuration = Duration(seconds: 12);

  P2PService({
    required this.roomCode,
    required this.username,
    required this.otherUser,
  }) {
    _me = username.toLowerCase().trim();
    _peer = otherUser.toLowerCase().trim();
  }

  Future<void> connect() async {
    if (_me.isEmpty || _peer.isEmpty || _me == _peer) {
      _statusController.add('invalid_users');
      return;
    }

    _isOfferer = _me.compareTo(_peer) < 0;
    _statusController.add('connecting');

    await WebRtcIce.load();
    _pc = await createPeerConnection(WebRtcIce.config);

    // Negotiated DC: оба создают канал с одним id — без onDataChannel.
    _channel = await _pc!.createDataChannel(
      'chat',
      RTCDataChannelInit()
        ..ordered = true
        ..negotiated = true
        ..id = 1,
    );
    _setupChannel(_channel!);

    _pc!.onIceCandidate = (candidate) {
      if (_closed) return;
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      _sendSignal('candidate', {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    _pc!.onConnectionState = (state) {
      if (_closed) return;
      _statusController.add('pc:$state');
      // Не считаем P2P открытым только по PC connected — ждём DC.
      if (state ==
              RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state ==
              RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        if (!_opened) {
          _statusController.add('pc_failed');
        }
      }
    };

    _pc!.onIceConnectionState = (state) {
      if (_closed) return;
      _statusController.add('ice:$state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _statusController.add('ice_failed');
      }
      // ICE connected/completed — только статус, open только через DC.
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _statusController.add('ice_ok');
        _tryMarkOpenFromDc();
      }
    };

    _signalSub = DyhanieApi.instance.events.listen(_onSignalEvent);

    // peer видит, что мы в чате
    await _sendSignal('p2p_hello', {'u': _me});

    if (_isOfferer) {
      await Future.delayed(const Duration(milliseconds: 600));
      if (_closed || _pc == null) return;
      await _createAndSendOffer();
      _armReoffers();
    } else {
      _statusController.add('waiting_offer');
    }

    _armOpenTimeout();
  }

  Future<void> _createAndSendOffer() async {
    if (_closed || _pc == null || _opened) return;
    // Уже есть remote answer / offer обработан — не долбим лишними offer
    if (_remoteSet && !_isOfferer) return;
    if (_makingOffer) return;

    _makingOffer = true;
    try {
      final offer = await _pc!.createOffer();
      if (_closed || _pc == null || _opened) return;
      await _pc!.setLocalDescription(offer);
      await _sendSignal('offer', {
        'type': offer.type,
        'sdp': offer.sdp,
      });
      _offerRound++;
      _statusController.add(
        _offerRound <= 1 ? 'offer_sent' : 'offer_resend_$_offerRound',
      );
    } catch (e) {
      _statusController.add('offer_error:$e');
    } finally {
      _makingOffer = false;
    }
  }

  void _armReoffers() {
    _reofferTimer?.cancel();
    if (!_isOfferer || _closed) return;

    void schedule(int index) {
      if (index >= _reofferDelays.length) return;
      _reofferTimer = Timer(_reofferDelays[index], () async {
        if (_closed || _opened) return;
        // Если remote уже set — re-offer обычно вреден
        if (_remoteSet) return;
        await _createAndSendOffer();
        schedule(index + 1);
      });
    }

    schedule(0);
  }

  void _armOpenTimeout() {
    _openTimeout?.cancel();
    _openTimeout = Timer(_openTimeoutDuration, () {
      if (_closed || _opened) return;
      _statusController.add('need_restart');
    });
  }

  Future<void> _sendSignal(String kind, dynamic data) async {
    try {
      await DyhanieApi.instance.signal(
        room: roomCode,
        to: _peer,
        kind: kind,
        data: data,
      );
    } catch (e) {
      _statusController.add('signal_err:$e');
    }
  }

  void _onSignalEvent(Map<String, dynamic> msg) {
    if (_closed || _pc == null) return;
    if (msg['type']?.toString() != 'signal') return;

    final p = msg['payload'];
    if (p is! Map) return;

    final room = (p['room']?.toString() ?? '').toLowerCase().trim();
    final from = (p['from']?.toString() ?? '').toLowerCase().trim();
    final kind = p['kind']?.toString() ?? '';

    if (room != roomCode.toLowerCase().trim()) return;
    if (from != _peer) return;

    final data = p['data'];

    // Второй зашёл в чат → offerer шлёт offer, если ещё не открыто
    if (kind == 'p2p_hello') {
      if (_isOfferer && !_opened && !_closed && !_remoteSet) {
        _createAndSendOffer();
      }
      return;
    }

    if (kind == 'offer' || kind == 'answer') {
      _handleSdp(kind, data);
    } else if (kind == 'candidate') {
      _handleCandidate(data);
    }
  }

  Future<void> _handleSdp(String kind, dynamic data) async {
    if (_pc == null || data is! Map) return;
    if (_opened) return;

    final type = data['type']?.toString() ?? kind;
    final sdp = data['sdp']?.toString();
    if (sdp == null || sdp.isEmpty) return;

    // --- Perfect Negotiation (упрощённо) ---
    // Offerer = impolite: при своём makingOffer игнорирует входящий offer.
    // Answerer = polite: принимает offer, при конфликте откатывается.
    if (kind == 'offer') {
      final readyForOffer =
          !_makingOffer && _pc!.signalingState !=
              RTCSignalingState.RTCSignalingStateHaveLocalOffer;

      if (_isOfferer) {
        // impolite: свой offer важнее
        if (_makingOffer ||
            _pc!.signalingState ==
                RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
          _statusController.add('glare_ignore_offer');
          return;
        }
      } else {
        // polite: если сами как-то в have-local-offer — rollback не везде
        // поддерживается в flutter_webrtc; просто примем новый offer.
        if (!readyForOffer && _offerHandled && _remoteSet) {
          // повторный offer от peer после сброса
          _offerHandled = false;
          _remoteSet = false;
        }
      }

      if (_offerHandled && _remoteSet && kind == 'offer') {
        // Повторный offer до open — разрешаем один раз переустановить
        _offerHandled = false;
        _remoteSet = false;
        _statusController.add('offer_replace');
      }

      if (_offerHandled) return;
    }

    if (kind == 'answer' && !_isOfferer) {
      // Answerer не должен получать answer
      return;
    }

    try {
      await _pc!.setRemoteDescription(RTCSessionDescription(sdp, type));
      _remoteSet = true;
      if (kind == 'offer') _offerHandled = true;
      _statusController.add('remote_set');

      // Отложенные ICE
      for (final c in List<RTCIceCandidate>.from(_pendingCandidates)) {
        try {
          await _pc!.addCandidate(c);
        } catch (_) {}
      }
      _pendingCandidates.clear();

      if (!_isOfferer && kind == 'offer') {
        final answer = await _pc!.createAnswer();
        if (_closed || _pc == null) return;
        await _pc!.setLocalDescription(answer);
        await _sendSignal('answer', {
          'type': answer.type,
          'sdp': answer.sdp,
        });
        _statusController.add('answer_sent');
      }

      _tryMarkOpenFromDc();
    } catch (e) {
      _statusController.add('sdp_error:$e');
    }
  }

  Future<void> _handleCandidate(dynamic data) async {
    if (_pc == null || data is! Map) return;
    try {
      final candStr = data['candidate']?.toString();
      final sdpMid = data['sdpMid']?.toString();
      int? sdpMLineIndex;
      final raw = data['sdpMLineIndex'];
      if (raw is int) {
        sdpMLineIndex = raw;
      } else if (raw is double) {
        sdpMLineIndex = raw.toInt();
      } else if (raw != null) {
        sdpMLineIndex = int.tryParse(raw.toString());
      }
      if (candStr == null || candStr.isEmpty) return;

      final candidate = RTCIceCandidate(candStr, sdpMid, sdpMLineIndex);
      if (!_remoteSet) {
        _pendingCandidates.add(candidate);
        return;
      }
      await _pc!.addCandidate(candidate);
      _statusController.add('cand_added');
    } catch (e) {
      _statusController.add('cand_error:$e');
    }
  }

  void _setupChannel(RTCDataChannel channel) {
    channel.onMessage = (message) {
      if (message.isBinary) {
        final bin = message.binary;
        unawaited(_crypto?.handlePacket(Uint8List.fromList(bin)));
        return;
      }
    };
    channel.onDataChannelState = (state) {
      _statusController.add('dc:$state');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        unawaited(_startCrypto());
      }
      if (state == RTCDataChannelState.RTCDataChannelClosed ||
          state == RTCDataChannelState.RTCDataChannelClosing) {
        if (_opened) {
          _statusController.add('dc_closed');
        }
      }
    };
  }

  Future<void> _startCrypto() async {
    if (_closed) return;
    final key = DyhanieKey.instance;
    if (!key.hasIdentity) {
      _statusController.add('crypto_no_identity');
      return;
    }
    try {
      _crypto?.destroy();
      _crypto = key.attachSession(
        peerId: _peer,
        onSend: (pkt) {
          if (_closed || _channel == null) return;
          try {
            _channel!.send(RTCDataChannelMessage.fromBinary(pkt));
          } catch (e) {
            _statusController.add('crypto_send_err:$e');
          }
        },
        onPlaintext: (plain) {
          if (_closed) return;
          final t = utf8.decode(plain, allowMalformed: true);
          if (t.isNotEmpty) _messageController.add(t);
        },
        onState: (s) {
          if (_closed) return;
          _statusController.add('crypto:$s');
          if (s == SessionState.active) {
            unawaited(_onCryptoActive());
          } else if (s == SessionState.destroyed) {
            _statusController.add('crypto_fail:${_crypto?.lastError ?? ''}');
          }
        },
      );
      await _crypto!.start();
    } catch (e) {
      _statusController.add('crypto_err:$e');
    }
  }

  Future<void> _onCryptoActive() async {
    if (_closed) return;
    final pack = _crypto?.remotePack;
    if (pack != null) {
      final tofu = await DyhanieKey.instance.rememberPeer(_peer, pack);
      if (_closed) return;
      if (tofu == TofuCheck.changed) {
        _crypto?.fail('tofu_changed');
        _statusController.add('crypto_key_changed');
        return;
      }
      if (tofu == TofuCheck.first) {
        _statusController.add('crypto_first_contact');
      }
    }
    _markOpen();
  }

  /// Open только если DC реально open.
  void _tryMarkOpenFromDc() {
    if (_closed || _opened) return;
    if (_crypto?.state == SessionState.active) {
      _markOpen();
    }
  }

  void _markOpen() {
    if (_opened || _closed) return;
    final ch = _channel;
    if (ch == null || ch.state != RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }
    _opened = true;
    _reofferTimer?.cancel();
    _reofferTimer = null;
    _openTimeout?.cancel();
    _openTimeout = null;
    _statusController.add('p2p_open');
  }

  void send(String text) {
    if (!isOpen) return;
    final crypto = _crypto;
    if (crypto == null || crypto.state != SessionState.active) return;
    try {
      unawaited(crypto.sendPlaintext(Uint8List.fromList(utf8.encode(text))));
    } catch (e) {
      _statusController.add('send_err:$e');
    }
  }

  /// Реально готов слать сообщения.
  bool get isOpen =>
      !_closed &&
      _opened &&
      _channel != null &&
      _channel!.state == RTCDataChannelState.RTCDataChannelOpen;

  Future<void> dispose() async {
    _closed = true;
    _opened = false;
    _crypto?.destroy();
    _crypto = null;
    _reofferTimer?.cancel();
    _reofferTimer = null;
    _openTimeout?.cancel();
    _openTimeout = null;
    await _signalSub?.cancel();
    _signalSub = null;
    _pendingCandidates.clear();
    try {
      await _channel?.close();
    } catch (_) {}
    _channel = null;
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    if (!_messageController.isClosed) {
      await _messageController.close();
    }
    if (!_statusController.isClosed) {
      await _statusController.close();
    }
  }
}