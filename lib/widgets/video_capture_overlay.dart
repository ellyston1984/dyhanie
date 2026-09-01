import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../compat/local_fs.dart';

/// PiP-окно камеры поверх чата.
class VideoCaptureOverlay extends StatefulWidget {
  final VoidCallback onReady;
  final void Function(String path, int durationMs) onFinished;
  final VoidCallback onCancel;
  final int maxSeconds;

  const VideoCaptureOverlay({
    super.key,
    required this.onReady,
    required this.onFinished,
    required this.onCancel,
    this.maxSeconds = 20,
  });

  @override
  State<VideoCaptureOverlay> createState() => VideoCaptureOverlayState();
}

class VideoCaptureOverlayState extends State<VideoCaptureOverlay> {
  CameraController? _ctrl;
  bool _ready = false;
  bool _recording = false;
  DateTime? _started;
  Timer? _tick;
  int _elapsedMs = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        if (mounted) setState(() => _error = 'Нет камеры');
        return;
      }
      final front = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cams.first,
      );
      final ctrl = CameraController(
        front,
        ResolutionPreset.medium,
        enableAudio: true,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await ctrl.initialize();
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      setState(() {
        _ctrl = ctrl;
        _ready = true;
        _error = null;
      });
      // после кадра, чтобы key/state уже в дереве
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onReady();
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> startRecording() async {
    final c = _ctrl;
    if (c == null || !_ready || _recording) return;
    try {
      await c.startVideoRecording();
      _started = DateTime.now();
      _recording = true;
      _elapsedMs = 0;
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!_recording || _started == null || !mounted) return;
        final ms = DateTime.now().difference(_started!).inMilliseconds;
        setState(() => _elapsedMs = ms);
        if (ms >= widget.maxSeconds * 1000) {
          stopRecording(send: true);
        }
      });
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = 'Старт: $e');
    }
  }

  Future<void> stopRecording({required bool send}) async {
    _tick?.cancel();
    _tick = null;
    if (!_recording) {
      if (!send) widget.onCancel();
      return;
    }
    _recording = false;
    final started = _started;
    _started = null;
    try {
      final c = _ctrl;
      if (c == null) {
        widget.onCancel();
        return;
      }
      final file = await c.stopVideoRecording();
      final ms = started == null
          ? 0
          : DateTime.now().difference(started).inMilliseconds;
      if (!send || ms < 400) {
        await deleteFilePath(file.path);
        widget.onCancel();
        return;
      }
      widget.onFinished(file.path, ms.clamp(0, widget.maxSeconds * 1000));
    } catch (_) {
      widget.onCancel();
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _ctrl?.dispose();
    super.dispose();
  }

  Widget _preview() {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
        ),
      );
    }

    // CameraPreview без cover часто даёт чёрный/обрезанный кадр в фиксированном боксе
    final sz = c.value.previewSize;
    if (sz == null) {
      return CameraPreview(c);
    }

    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        // previewSize: width/height в ориентации сенсора; для портрета меняем местами
        width: sz.height,
        height: sz.width,
        child: CameraPreview(c),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final w = (mq.size.width * 0.44).clamp(140.0, 220.0);
    final h = w * 16 / 9;

    // Сверху справа — не под input/media strip
    return Positioned(
      top: mq.padding.top + kToolbarHeight + 12,
      right: 12,
      child: Material(
        elevation: 12,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        color: Colors.black,
        child: SizedBox(
          width: w,
          height: h,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_error != null)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.white70, fontSize: 11),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              else
                _preview(),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: Colors.black54,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    _recording
                        ? '● ${(_elapsedMs / 1000).floor()} / ${widget.maxSeconds} с'
                        : (_ready ? 'Запись…' : 'Камера…'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}