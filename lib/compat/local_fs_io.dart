import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<Uint8List?> readFileBytes(String path) async {
  try {
    final f = File(path);
    if (!await f.exists()) return null;
    return await f.readAsBytes();
  } catch (_) {
    return null;
  }
}

Future<bool> fileExists(String path) async {
  try {
    return await File(path).exists();
  } catch (_) {
    return false;
  }
}

Future<void> deleteFilePath(String path) async {
  try {
    final f = File(path);
    if (await f.exists()) await f.delete();
  } catch (_) {}
}

Future<void> writeFileBytes(String path, List<int> bytes) async {
  await File(path).writeAsBytes(bytes, flush: true);
}

Future<String> createDir(String path) async {
  final d = Directory(path);
  if (!await d.exists()) await d.create(recursive: true);
  return d.path;
}

Future<void> deleteDirRecursive(String path) async {
  try {
    final d = Directory(path);
    if (await d.exists()) await d.delete(recursive: true);
  } catch (_) {}
}

Future<void> deleteFilesMatching(String dirPath, String needle) async {
  try {
    final d = Directory(dirPath);
    if (!await d.exists()) return;
    await for (final e in d.list()) {
      if (e is File && e.path.contains(needle)) {
        await e.delete();
      }
    }
  } catch (_) {}
}

Future<String> documentsPath() async {
  final root = await getApplicationDocumentsDirectory();
  return root.path;
}

Future<String> temporaryPath() async {
  final root = await getTemporaryDirectory();
  return root.path;
}
