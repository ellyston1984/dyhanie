import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'video_open.dart';

class VideoMessageBubble extends StatefulWidget {
  final String base64Data;
  final double size;
  final String messageKey;

  const VideoMessageBubble({
    super.key,
    required this.base64Data,
    required this.messageKey,
    this.size = 96,
  });

  @override
  State<VideoMessageBubble> createState() => _VideoMessageBubbleState();
}

class _VideoMessageBubbleState extends State<VideoMessageBubble> {
  VideoPlayerController? _controller;
  bool _loading = false;
  bool _ready = false;
  bool _playing = false;

  double get _s => widget.size.clamp(48.0, 2000.0);

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_loading) return;

    if (_controller != null && _ready) {
      if (_controller!.value.isPlaying) {
        await _controller!.pause();
        if (mounted) setState(() => _playing = false);
      } else {
        await _controller!.play();
        if (mounted) setState(() => _playing = true);
      }
      return;
    }

    setState(() => _loading = true);
    try {
      final clean = widget.base64Data.contains(',')
          ? widget.base64Data.split(',').last.trim()
          : widget.base64Data.trim();
      final bytes = base64Decode(clean);
      final c = await openVideoFromBytes(bytes, widget.messageKey);
      await c.initialize();
      c.setLooping(true);
      c.addListener(() {
        if (!mounted) return;
        final p = c.value.isPlaying;
        if (p != _playing) setState(() => _playing = p);
      });

      await _controller?.dispose();
      _controller = c;
      await c.play();
      if (mounted) {
        setState(() {
          _ready = true;
          _loading = false;
          _playing = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('Видео: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final onSurf = Theme.of(context).colorScheme.onSurface;

    return GestureDetector(
      onTap: _toggle,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_s * 0.18),
        child: Container(
          width: _s,
          height: _s,
          color: onSurf.withValues(alpha: 0.12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_ready && _controller != null)
                FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _controller!.value.size.width,
                    height: _controller!.value.size.height,
                    child: VideoPlayer(_controller!),
                  ),
                ),
              if (_loading)
                const Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (!_playing)
                Center(
                  child: Icon(
                    Icons.play_circle_fill,
                    size: _s * 0.42,
                    color: onSurf.withValues(alpha: 0.9),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}