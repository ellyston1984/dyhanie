import 'dart:convert';

import '../compat/local_fs.dart';

/// Локальный кэш voice/video (и при желании image) рядом с историей чата.
class MediaMessageCache {
  MediaMessageCache._();
  static final instance = MediaMessageCache._();

  Future<String> _dirForRoom(String roomCode) async {
    final root = await documentsPath();
    if (root.isEmpty) return '';
    final safe = roomCode.replaceAll(RegExp(r'[^\w\-\.]'), '_');
    return createDir('$root/chat_media/$safe');
  }

  Future<String> _path(String roomCode, String msgKey, String ext) async {
    final dir = await _dirForRoom(roomCode);
    if (dir.isEmpty) return '';
    final safeKey = msgKey.replaceAll(RegExp(r'[^\w\-\.]'), '_');
    return '$dir/$safeKey.$ext';
  }

  String _extFor(String? msgType, String? mime) {
    if (msgType == 'voice' || (mime?.startsWith('audio') ?? false)) {
      return 'm4a';
    }
    if (msgType == 'video' || (mime?.startsWith('video') ?? false)) {
      return 'mp4';
    }
    if (msgType == 'image' || (mime?.startsWith('image') ?? false)) {
      return 'jpg';
    }
    return 'bin';
  }

  /// Сохранить base64 с диска; вернуть абсолютный путь.
  Future<String?> put({
    required String roomCode,
    required String msgKey,
    required String base64Data,
    String? msgType,
    String? mime,
  }) async {
    if (base64Data.isEmpty || msgKey.isEmpty) return null;
    try {
      final clean =
          base64Data.contains(',') ? base64Data.split(',').last : base64Data;
      final bytes = base64Decode(clean);
      if (bytes.isEmpty) return null;
      final ext = _extFor(msgType, mime);
      final path = await _path(roomCode, msgKey, ext);
      if (path.isEmpty) return null;
      await writeFileBytes(path, bytes);
      return path;
    } catch (_) {
      return null;
    }
  }

  /// Прочитать файл → base64 (для UI / play).
  Future<String?> getBase64(String? path) async {
    if (path == null || path.isEmpty) return null;
    try {
      final bytes = await readFileBytes(path);
      if (bytes == null || bytes.isEmpty) return null;
      return base64Encode(bytes);
    } catch (_) {
      return null;
    }
  }

  Future<void> deletePath(String? path) async {
    if (path == null || path.isEmpty) return;
    await deleteFilePath(path);
  }

  Future<void> deleteKey({
    required String roomCode,
    required String msgKey,
  }) async {
    try {
      final dir = await _dirForRoom(roomCode);
      if (dir.isEmpty) return;
      final safeKey = msgKey.replaceAll(RegExp(r'[^\w\-\.]'), '_');
      await deleteFilesMatching(dir, safeKey);
    } catch (_) {}
  }

  /// Вся медиа папки комнаты (wipe / clear history).
  Future<void> clearRoom(String roomCode) async {
    try {
      final dir = await _dirForRoom(roomCode);
      if (dir.isNotEmpty) await deleteDirRecursive(dir);
    } catch (_) {}
  }
}