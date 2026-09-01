import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../services/font_service.dart';

/// Общий плеер: одновременно играет только одно голосовое.
class VoicePlayback {
  VoicePlayback._();
  static final instance = VoicePlayback._();

  final AudioPlayer player = AudioPlayer();
  String? currentKey;

  Future<void> stop() async {
    try {
      await player.stop();
    } catch (_) {}
    currentKey = null;
  }
}

class VoiceMessageBubble extends StatefulWidget {
  final String messageKey;
  final String base64Data;
  final int durationMs;
  final Color onSurf;
  final double fontSize;

  const VoiceMessageBubble({
    super.key,
    required this.messageKey,
    required this.base64Data,
    required this.durationMs,
    required this.onSurf,
    required this.fontSize,
  });

  @override
  State<VoiceMessageBubble> createState() => _VoiceMessageBubbleState();
}

class _VoiceMessageBubbleState extends State<VoiceMessageBubble> {
  bool _playing = false;
  bool _loading = false;
  Duration _pos = Duration.zero;
  Duration _total = Duration.zero;
  StreamSubscription? _completeSub;
  StreamSubscription? _posSub;
  StreamSubscription? _durSub;

  @override
  void initState() {
    super.initState();
    final ms = widget.durationMs;
    if (ms > 0) {
      _total = Duration(milliseconds: ms.clamp(0, 60000));
    }

    final player = VoicePlayback.instance.player;
    _completeSub = player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      if (VoicePlayback.instance.currentKey == widget.messageKey) {
        setState(() {
          _playing = false;
          _pos = Duration.zero;
        });
        VoicePlayback.instance.currentKey = null;
      }
    });

    _posSub = player.onPositionChanged.listen((d) {
      if (!mounted) return;
      if (VoicePlayback.instance.currentKey == widget.messageKey) {
        setState(() => _pos = d);
      }
    });

    _durSub = player.onDurationChanged.listen((d) {
      if (!mounted) return;
      if (VoicePlayback.instance.currentKey == widget.messageKey &&
          d.inMilliseconds > 0) {
        setState(() => _total = d);
      }
    });
  }

  @override
  void dispose() {
    _completeSub?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    super.dispose();
  }

  String _fmt(Duration d) {
    final s = d.inSeconds.clamp(0, 999);
    final m = s ~/ 60;
    final r = s % 60;
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  Future<void> _toggle() async {
    final vp = VoicePlayback.instance;

    // этот же играет → стоп
    if (_playing && vp.currentKey == widget.messageKey) {
      await vp.stop();
      if (mounted) {
        setState(() {
          _playing = false;
          _pos = Duration.zero;
        });
      }
      return;
    }

    // другой играет → стоп
    if (vp.currentKey != null && vp.currentKey != widget.messageKey) {
      await vp.stop();
    }

    setState(() => _loading = true);
    try {
      final clean = widget.base64Data.contains(',')
          ? widget.base64Data.split(',').last.trim()
          : widget.base64Data.trim();
      final bytes = base64Decode(clean);

      vp.currentKey = widget.messageKey;
      await vp.player.play(BytesSource(bytes));
      if (mounted) {
        setState(() {
          _playing = true;
          _loading = false;
        });
      }
    } catch (e) {
      vp.currentKey = null;
      if (mounted) {
        setState(() {
          _playing = false;
          _loading = false;
        });
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('Play: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final onSurf = widget.onSurf;
    final show = _playing && _total.inMilliseconds > 0
        ? _fmt(_pos)
        : _fmt(_total.inMilliseconds > 0
            ? _total
            : Duration(milliseconds: widget.durationMs.clamp(0, 60000)));

    return InkWell(
      onTap: _loading ? null : _toggle,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_loading)
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: onSurf.withValues(alpha: 0.7),
                ),
              )
            else
              Icon(
                _playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
                size: 28,
                color: onSurf.withValues(alpha: 0.85),
              ),
            const SizedBox(width: 8),
            Text(
              '🎤 $show',
              style: FontService.style(
                color: onSurf,
                fontSize: widget.fontSize,
              ),
            ),
          ],
        ),
      ),
    );
  }
}