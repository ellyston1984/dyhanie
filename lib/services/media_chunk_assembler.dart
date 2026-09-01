import 'dart:convert';

import 'media_chunk_codec.dart';

class _Assembly {
  final int total;
  final String msgType;
  final String? mime;
  final int? durationMs;
  final int? ttl;
  final String? from;
  final String? replyText;
  final String? replyUser;
  final List<String?> parts;
  final DateTime started = DateTime.now();

  _Assembly({
    required this.total,
    required this.msgType,
    this.mime,
    this.durationMs,
    this.ttl,
    this.from,
    this.replyText,
    this.replyUser,
  }) : parts = List<String?>.filled(total, null);

  bool get complete => parts.every((e) => e != null);
}

class MediaChunkAssembler {
  MediaChunkAssembler._();
  static final instance = MediaChunkAssembler._();

  final _map = <String, _Assembly>{};
  static const _ttl = Duration(minutes: 10);

  /// null = ещё не собрано; Map = готовое сообщение для ленты
  Map<String, dynamic>? add(Map<String, dynamic> chunk) {
    _gc();
    final mediaId = chunk['media_id']?.toString() ?? '';
    final index = chunk['index'] is int
        ? chunk['index'] as int
        : int.tryParse('${chunk['index']}') ?? -1;
    final total = chunk['total'] is int
        ? chunk['total'] as int
        : int.tryParse('${chunk['total']}') ?? 0;
    final data = chunk['data']?.toString();
    if (mediaId.isEmpty || data == null || index < 0 || total < 1) {
      return null;
    }

    var a = _map[mediaId];
    if (a == null) {
      a = _Assembly(
        total: total,
        msgType: chunk['msg_type']?.toString() ?? 'video',
        mime: chunk['mime']?.toString(),
        durationMs: chunk['duration_ms'] is int
            ? chunk['duration_ms'] as int
            : null,
        ttl: chunk['ttl'] is int ? chunk['ttl'] as int : null,
        from: chunk['from']?.toString(),
        replyText: chunk['replyText']?.toString(),
        replyUser: chunk['replyUser']?.toString(),
      );
      _map[mediaId] = a;
    }
    if (index >= a.total) return null;
    a.parts[index] = data;

    if (!a.complete) return null;

    _map.remove(mediaId);
   final bytes = MediaChunkCodec.joinBase64(a.parts);
    _map.remove(mediaId);
    final b64 = base64Encode(bytes);
    return {
      'key': mediaId,
      'text': '',
      'username': a.from ?? '',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'ttl': a.ttl ?? 0,
      'media': b64,
      'image': a.msgType == 'image' ? b64 : null,
      'msg_type': a.msgType,
      'duration_ms': a.durationMs,
      'mime': a.mime,
      'replyText': a.replyText,
      'replyUser': a.replyUser,
      'status': 'delivered',
    };
  }

  void _gc() {
    final now = DateTime.now();
    _map.removeWhere((_, a) => now.difference(a.started) > _ttl);
  }
}
   
