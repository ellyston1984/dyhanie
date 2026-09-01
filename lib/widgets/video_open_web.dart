import 'dart:typed_data';

import 'package:video_player/video_player.dart';

Future<VideoPlayerController> openVideoFromBytes(
  Uint8List bytes,
  String key,
) async {
  final uri = Uri.dataFromBytes(bytes, mimeType: 'video/mp4');
  return VideoPlayerController.networkUrl(uri);
}
