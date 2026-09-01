import 'dart:typed_data';

Future<Uint8List?> readFileBytes(String path) async => null;

Future<bool> fileExists(String path) async => false;

Future<void> deleteFilePath(String path) async {}

Future<void> writeFileBytes(String path, List<int> bytes) async {}

Future<String> createDir(String path) async => path;

Future<void> deleteDirRecursive(String path) async {}

Future<void> deleteFilesMatching(String dirPath, String needle) async {}

Future<String> documentsPath() async => '';

Future<String> temporaryPath() async => '';
