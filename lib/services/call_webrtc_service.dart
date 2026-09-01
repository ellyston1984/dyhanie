import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'dyhanie_api.dart';
import 'webrtc_ice.dart';

/// Только аудиозвонок. Сигналинг — DyhanieApi.signal (call_offer/answer/candidate).
class CallWebRTCService {
  final String roomCode;
  final String username;
  final String otherUser;
  final bool isCaller;
  final Map? initialOffer;

  CallWebRTCService({
    required this.roomCode,
    required this.username,
    required this.otherUser,
    required this.isCaller,
    this.initialOffer,
  });

  RTCPeerConnection? _pc;
  MediaStream? _localStream;

  bool _remoteDescSet = false;
  bool _answerSet = false;
  bool _disposed = false;
  bool _started = false;

  final List<RTCIceCandidate> _pendingCandidates = [];

  final _remoteStreamCtrl = StreamController<MediaStream>.broadcast();
  Stream<MediaStream> get remoteStream => _remoteStreamCtrl.stream;

  final _statusCtrl = StreamController<String>.broadcast();
  Stream<String> get status => _statusCtrl.stream;

  StreamSubscription? _signalSub;

  Future<void> start() async {
    if (_disposed || _started) return;
    _started = true;
    _statusCtrl.add('init');

    await WebRtcIce.load();
    _pc = await createPeerConnection(WebRtcIce.config);

    _pc!.onIceCandidate = (RTCIceCandidate c) {
      if (_disposed || c.candidate == null || c.candidate!.isEmpty) return;
      _sendSignal('call_candidate', {
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };

    _pc!.onConnectionState = (state) {
      if (_disposed) return;
      _statusCtrl.add('pc:$state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _statusCtrl.add('connected');
      }
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _statusCtrl.add('link_lost');
      }
    };

    _pc!.onTrack = (RTCTrackEvent e) {
      if (_disposed) return;
      if (e.streams.isNotEmpty) {
        _remoteStreamCtrl.add(e.streams.first);
        _statusCtrl.add('remote_audio');
      }
    };

    // Только микрофон
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': false,
    });
    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }
    for (final t in _localStream!.getAudioTracks()) {
      try {
        await t.applyConstraints({
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        });
      } catch (_) {}
    }
    _statusCtrl.add('mic_ok');

    try {
      await Helper.setSpeakerphoneOn(false);
    } catch (_) {}

    _signalSub = DyhanieApi.instance.events.listen(_onSignal);

    if (isCaller) {
      await _createOffer();
    } else {
      _statusCtrl.add('waiting_offer');
      if (initialOffer != null) {
        await _applyOffer(initialOffer);
      }
    }
  }

  Future<void> _sendSignal(String kind, dynamic data) async {
    if (_disposed) return;
    try {
      final api = DyhanieApi.instance;
      if (!api.isConnected) await api.connect();
      final me = username.toLowerCase().trim();
      if (api.boundUsername?.toLowerCase() != me) {
        await api.sessionBind(me);
      }
      await api.signal(
        room: roomCode,
        to: otherUser.toLowerCase().trim(),
        kind: kind,
        data: data is Map ? Map<String, dynamic>.from(data) : data,
      );
    } catch (e) {
      _statusCtrl.add('signal_err:$e');
    }
  }

  void _onSignal(Map<String, dynamic> msg) {
    if (_disposed || _pc == null) return;
    if (msg['type']?.toString() != 'signal') return;
    final p = msg['payload'];
    if (p is! Map) return;
    if ((p['room']?.toString() ?? '').toLowerCase().trim() !=
        roomCode.toLowerCase().trim()) {
      return;
    }

    final from = (p['from']?.toString() ?? '').toLowerCase().trim();
    if (from != otherUser.toLowerCase().trim()) return;

    final kind = p['kind']?.toString();
    final data = p['data'];
    if (kind == 'call_offer') {
      unawaited(_applyOffer(data));
    } else if (kind == 'call_answer') {
      unawaited(_applyAnswer(data));
    } else if (kind == 'call_candidate') {
      unawaited(_applyCandidate(data));
    }
  }

  Future<void> _createOffer() async {
    if (_pc == null || _disposed) return;
    final offer = await _pc!.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': false,
    });
    await _pc!.setLocalDescription(offer);
    await _sendSignal('call_offer', {
      'sdp': offer.sdp,
      'type': offer.type,
      'from': username,
    });
    _statusCtrl.add('offer_sent');
  }

  Future<void> _applyOffer(dynamic data) async {
    if (_disposed || _pc == null || _remoteDescSet) return;
    if (data is! Map) return;

    final sdp = data['sdp']?.toString();
    final type = data['type']?.toString();
    if (sdp == null || type == null) return;

    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, type));
    _remoteDescSet = true;

    final answer = await _pc!.createAnswer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': false,
    });
    await _pc!.setLocalDescription(answer);
    await _sendSignal('call_answer', {
      'sdp': answer.sdp,
      'type': answer.type,
      'from': username,
    });
    _statusCtrl.add('answer_sent');
    await _flushCandidates();
  }

  Future<void> _applyAnswer(dynamic data) async {
    if (_disposed || _pc == null || _answerSet) return;
    if (data is! Map) return;

    final sdp = data['sdp']?.toString();
    final type = data['type']?.toString();
    if (sdp == null || type == null) return;

    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, type));
    _answerSet = true;
    _remoteDescSet = true;
    _statusCtrl.add('answer_set');
    await _flushCandidates();
  }

  Future<void> _applyCandidate(dynamic data) async {
    if (_disposed || _pc == null || data is! Map) return;

    final c = RTCIceCandidate(
      data['candidate']?.toString(),
      data['sdpMid']?.toString(),
      data['sdpMLineIndex'] is int
          ? data['sdpMLineIndex'] as int
          : int.tryParse('${data['sdpMLineIndex']}'),
    );

    if (!_remoteDescSet) {
      _pendingCandidates.add(c);
      return;
    }
    try {
      await _pc!.addCandidate(c);
    } catch (_) {}
  }

  Future<void> _flushCandidates() async {
    for (final c in List<RTCIceCandidate>.from(_pendingCandidates)) {
      try {
        await _pc?.addCandidate(c);
      } catch (_) {}
    }
    _pendingCandidates.clear();
  }

  Future<void> setMuted(bool muted) async {
    for (final t in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
  }

  Future<void> setSpeaker(bool on) async {
    try {
      await Helper.setSpeakerphoneOn(on);
    } catch (_) {}
  }

  Future<void> hangUp() async {
    if (_disposed) return;
    _disposed = true;
    await _signalSub?.cancel();
    _signalSub = null;

    for (final t in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await t.stop();
    }
    await _localStream?.dispose();
    _localStream = null;

    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;

    try {
      await Helper.setSpeakerphoneOn(false);
    } catch (_) {}

    if (!_statusCtrl.isClosed) _statusCtrl.add('ended');
  }

  void dispose() {
    unawaited(hangUp());
    if (!_remoteStreamCtrl.isClosed) _remoteStreamCtrl.close();
    if (!_statusCtrl.isClosed) _statusCtrl.close();
  }
}