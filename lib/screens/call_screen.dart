import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/call_webrtc_service.dart';
import '../services/font_service.dart';
import '../services/locale_service.dart';
import '../services/dyhanie_api.dart';

class CallScreen extends StatefulWidget {
  final String roomCode;
  final String username;
  final String? otherUser;
  final bool isIncoming;
  final Map? initialOffer;

  const CallScreen({
    super.key,
    required this.roomCode,
    required this.username,
    required this.otherUser,
    required this.isIncoming,
    this.initialOffer,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  CallWebRTCService? _rtc;
  final _remoteRenderer = RTCVideoRenderer();

  late String statusText;
  bool muted = false;
  bool speakerOn = false;
  bool connected = false;
  bool _closing = false;
  bool _accepted = false;

  Timer? _timer;
  Timer? _ringTimeout;
  int seconds = 0;

  StreamSubscription? _peerSignalSub;
  StreamSubscription? _rtcStatusSub;
  StreamSubscription? _remoteSub;

  @override
  void initState() {
    super.initState();
    _initRenderer();
    _listenPeerSignals();

    if (widget.isIncoming) {
      _accepted = false;
      statusText = L.t('incoming_call');
    } else {
      _accepted = true;
      statusText = L.t('call_connecting');
      _startRtc();
    }

    _ringTimeout = Timer(const Duration(seconds: 111), () async {
      if (!connected && mounted && !_closing) {
        await _finish();
      }
    });
  }

  Future<void> _initRenderer() async {
    await _remoteRenderer.initialize();
  }

  void _attachRemote(MediaStream stream) {
    _remoteRenderer.srcObject = stream;
    if (!mounted) return;
    setState(() {
      connected = true;
      statusText = L.t('call_in_progress');
    });
    _startTimer();
    HapticFeedback.lightImpact();
    // зафиксировать телефон/динамик после появления remote
    unawaited(_rtc?.setSpeaker(speakerOn) ?? Future.value());
  }

  void _listenPeerSignals() {
    _peerSignalSub?.cancel();
    final other = widget.otherUser;
    if (other == null || other.isEmpty) return;

    _peerSignalSub = DyhanieApi.instance.events.listen((m) {
      if (_closing) return;
      if (m['type']?.toString() != 'signal') return;
      final p = m['payload'];
      if (p is! Map) return;
      if ((p['room']?.toString() ?? '').toLowerCase().trim() !=
          widget.roomCode.toLowerCase().trim()) {
        return;
      }
      if ((p['from']?.toString() ?? '').toLowerCase().trim() !=
          other.toLowerCase().trim()) {
        return;
      }

      final kind = p['kind']?.toString() ?? '';
      if (kind == 'call_decline' || kind == 'call_hangup') {
        if (mounted) {
          setState(() => statusText = L.t('decline_call'));
        }
        _finish(notifyPeer: false);
      }
    });
  }

  Future<void> _notifyPeer(String kind) async {
    final other = widget.otherUser;
    if (other == null || other.isEmpty) return;
    try {
      final api = DyhanieApi.instance;
      if (!api.isConnected) await api.connect();
      await api.signal(
        room: widget.roomCode,
        to: other,
        kind: kind,
        data: {'from': widget.username},
      );
    } catch (_) {}
  }

  Future<void> _accept() async {
    if (_accepted || _closing) return;
    setState(() {
      _accepted = true;
      statusText = L.t('call_connecting');
    });
    await _startRtc();
  }

  Future<void> _decline() async {
    await _notifyPeer('call_decline');
    await _finish(notifyPeer: false);
  }

  Future<void> _finish({bool notifyPeer = false}) async {
    if (_closing) return;
    _closing = true;
    _timer?.cancel();
    _ringTimeout?.cancel();
    if (notifyPeer) {
      await _notifyPeer('call_hangup');
    }
    await _rtc?.hangUp();
    if (mounted && Navigator.canPop(context)) {
      Navigator.pop(context);
    }
  }

  Future<void> _hangUp() async {
    if (_closing) return;
    await _finish(notifyPeer: true);
  }

  Future<void> _startRtc() async {
    final other = widget.otherUser;
    if (other == null || other.isEmpty) {
      setState(() => statusText = L.t('call_no_peer'));
      return;
    }

    final isCaller = !widget.isIncoming;

    _rtc = CallWebRTCService(
      roomCode: widget.roomCode,
      username: widget.username,
      otherUser: other,
      isCaller: isCaller,
      initialOffer: widget.initialOffer,
    );

    _remoteSub?.cancel();
    _remoteSub = _rtc!.remoteStream.listen(_attachRemote);

    _rtcStatusSub?.cancel();
    _rtcStatusSub = _rtc!.status.listen((s) {
      if (!mounted || _closing) return;
      setState(() {
        if (!connected) {
          if (s == 'mic_ok') {
            statusText =
                isCaller ? L.t('call_calling') : L.t('call_connecting');
          } else if (s == 'offer_sent') {
            statusText = L.t('call_calling');
          } else if (s == 'answer_sent' || s == 'answer_set') {
            statusText = L.t('call_connecting');
          } else if (s == 'link_lost') {
            statusText = L.t('call_link_lost');
          } else if (s.startsWith('Ошибка') ||
              s.startsWith('error') ||
              s.startsWith('signal_err')) {
            statusText = s;
          }
        }
        if (s == 'remote_audio' || s == 'connected') {
          connected = true;
          statusText = L.t('call_in_progress');
          _startTimer();
        }
      });
    });

    try {
      await _rtc!.start();
    } catch (e) {
      if (mounted) setState(() => statusText = '${L.t('error')}: $e');
    }
  }

  void _startTimer() {
    if (_timer != null) return;
    _ringTimeout?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => seconds++);
    });
  }

  String get _timeLabel {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _toggleMute() async {
    setState(() => muted = !muted);
    await _rtc?.setMuted(muted);
  }

  Future<void> _toggleSpeaker() async {
    setState(() => speakerOn = !speakerOn);
    await _rtc?.setSpeaker(speakerOn);
  }

  void _videoStub() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Видеозвонок скоро'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ringTimeout?.cancel();
    _rtcStatusSub?.cancel();
    _remoteSub?.cancel();
    _peerSignalSub?.cancel();
    _remoteRenderer.srcObject = null;
    _remoteRenderer.dispose();
    _rtc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final other = widget.otherUser ?? '…';
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final onSurf = Theme.of(context).colorScheme.onSurface;
    final incomingWait = widget.isIncoming && !_accepted;

    // ----- Экран ответа -----
    if (incomingWait) {
      return Scaffold(
        backgroundColor: bg,
        body: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 2),
              Text(
                '@$other',
                textAlign: TextAlign.center,
                style: FontService.style(fontSize: 28, color: onSurf),
              ),
              const SizedBox(height: 12),
              Text(
                L.t('incoming_call'),
                textAlign: TextAlign.center,
                style: FontService.style(
                  fontSize: 16,
                  color: onSurf.withValues(alpha: 0.55),
                ),
              ),
              const Spacer(flex: 3),
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 0, 32, 48),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _answerBtn(
                      icon: Icons.call_end,
                      color: Colors.redAccent,
                      label: L.t('decline_call'),
                      onTap: _decline,
                    ),
                    _answerBtn(
                      icon: Icons.call,
                      color: Colors.green,
                      label: L.t('accept_call'),
                      onTap: _accept,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    // ----- В звонке -----
    final underName = connected ? _timeLabel : statusText;

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              width: 1,
              height: 1,
              child: RTCVideoView(_remoteRenderer),
            ),
            Column(
              children: [
                const SizedBox(height: 56),
                Text(
                  '@$other',
                  textAlign: TextAlign.center,
                  style: FontService.style(fontSize: 28, color: onSurf),
                ),
                const SizedBox(height: 10),
                Text(
                  underName,
                  textAlign: TextAlign.center,
                  style: FontService.style(
                    fontSize: 16,
                    color: onSurf.withValues(alpha: 0.55),
                  ),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 36),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _circleBtn(
                        icon: muted ? Icons.mic_off : Icons.mic,
                        bg: muted
                            ? Colors.orangeAccent
                            : onSurf.withValues(alpha: 0.18),
                        onTap: _toggleMute,
                        label: muted ? 'Выкл' : 'Микрофон',
                      ),
                      _circleBtn(
                        icon: Icons.videocam_off,
                        bg: onSurf.withValues(alpha: 0.12),
                        onTap: _videoStub,
                        label: 'Скоро',
                      ),
                      _circleBtn(
                        icon: speakerOn ? Icons.volume_up : Icons.hearing,
                        bg: speakerOn
                            ? Colors.blueAccent
                            : onSurf.withValues(alpha: 0.18),
                        onTap: _toggleSpeaker,
                        label: speakerOn ? 'Динамик' : 'Телефон',
                      ),
                      _circleBtn(
                        icon: Icons.call_end,
                        bg: Colors.redAccent,
                        onTap: _hangUp,
                        size: 68,
                        label: 'Сброс',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _answerBtn({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    final onSurf = Theme.of(context).colorScheme.onSurface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(40),
          child: Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 34),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          label,
          style: FontService.style(
            fontSize: 14,
            color: onSurf.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }

  Widget _circleBtn({
    required IconData icon,
    required Color bg,
    required VoidCallback onTap,
    double size = 56,
    String? label,
  }) {
    final onSurf = Theme.of(context).colorScheme.onSurface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(size),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: size > 60 ? 30 : 24),
          ),
        ),
        if (label != null) ...[
          const SizedBox(height: 6),
          Text(
            label,
            style: FontService.style(
              fontSize: 11,
              color: onSurf.withValues(alpha: 0.45),
            ),
          ),
        ],
      ],
    );
  }
}