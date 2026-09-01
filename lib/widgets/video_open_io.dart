import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

Future<VideoPlayerController> openVideoFromBytes(
  Uint8List bytes,
  String key,
) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/vid_${key.hashCode}.mp4');
  await file.writeAsBytes(bytes, flush: true);
  return VideoPlayerController.file(file);
}
