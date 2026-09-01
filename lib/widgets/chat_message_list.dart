import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/font_service.dart';
import '../services/locale_service.dart';
import '../services/icon_style_service.dart';

import 'voice_message_bubble.dart';
import 'video_message_bubble.dart';

class ChatMessageList extends StatelessWidget {
  final List<Map<String, dynamic>> messages;
  final String myUsername;
  final double fontSize;
  final int videoSizeLevel; // 0=XS … 4=XL — только video
  final bool isSavedChat;
  final int selectedTime;
  final Map<String, int> remaining;
  final int? otherLastRead;
  final ScrollController scrollController;
  final void Function(Map<String, dynamic> msg) onLongPress;
  final void Function(String key) onSwipeDelete;

  const ChatMessageList({
    super.key,
    required this.messages,
    required this.myUsername,
    required this.fontSize,
    this.videoSizeLevel = 2,
    required this.isSavedChat,
    required this.selectedTime,
    required this.remaining,
    required this.otherLastRead,
    required this.scrollController,
    required this.onLongPress,
    required this.onSwipeDelete,
  });

  double _videoBubbleSize(BuildContext context) {
    final half = MediaQuery.sizeOf(context).width * 0.5;
    const m = 130.0; // бывший XL → новый M

    switch (videoSizeLevel.clamp(0, 4)) {
      case 0:
        return m * 0.45; // XS
      case 1:
        return m * 0.70; // S
      case 2:
        return m; // M
      case 3:
        return m + (half - m) * 0.5; // L
      case 4:
      default:
        return half; // XL ≈ половина экрана
    }
  }

  String _fmtTime(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Widget _statusIcon(Map msg, Color muted) {
    if (msg['username'] != myUsername) return const SizedBox.shrink();

    final status = msg['status']?.toString() ?? '';
    final pending = msg['pending'] == true || status == 'pending';

    if (pending) {
      return Icon(
        Icons.schedule,
        size: 14,
        color: Colors.orangeAccent.withValues(alpha: 0.9),
      );
    }
    if (status == 'error') {
      return const Icon(
        Icons.error_outline,
        size: 14,
        color: Colors.redAccent,
      );
    }

    final ts = msg['timestamp'] as int? ?? 0;
    final read = otherLastRead != null && otherLastRead! >= ts;
    return Icon(
      read ? Icons.done_all : Icons.done,
      size: 14,
      color: read ? Colors.lightBlueAccent : muted,
    );
  }

  @override
  Widget build(BuildContext context) {
    final onSurf = Theme.of(context).colorScheme.onSurface;

    if (messages.isEmpty) {
      return Center(
        child: Text(
          L.t('quiet_chat'),
          style: FontService.style(color: onSurf.withValues(alpha: 0.4)),
        ),
      );
    }

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: messages.length,
      itemBuilder: (context, i) {
        final msg = messages[i];
        final key = msg['key'] as String;
        final isMe = msg['username'] == myUsername;
        final rem = remaining[key];
        final text = msg['text']?.toString() ?? '';
        final isP2P = msg['p2p'] == true;
        final img = (msg['image']?.toString().isNotEmpty ?? false)
            ? msg['image'].toString()
            : ((msg['msg_type']?.toString() == 'image')
                ? msg['media']?.toString()
                : null);
        final ts = msg['timestamp'] as int? ?? 0;

        Widget bubble = Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: GestureDetector(
            onLongPress: () => onLongPress(msg),
            child: Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78,
              ),
              child: Column(
                crossAxisAlignment:
                    isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  if (!isMe)
                    Text(
                      '@${msg['username']}',
                      style: FontService.style(
                        color: onSurf.withValues(alpha: 0.55),
                        fontSize: fontSize - 3,
                      ),
                    ),
                  if (msg['replyText'] != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        '${msg['replyUser']}: ${msg['replyText']}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: FontService.style(
                          color: onSurf.withValues(alpha: 0.5),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  if (img != null && img.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          base64Decode(
                            img.contains(',')
                                ? img.split(',').last.trim()
                                : img,
                          ),
                          key: ValueKey('img_$key'),
                          gaplessPlayback: true,
                          fit: BoxFit.cover,
                          width: 200,
                          errorBuilder: (_, __, ___) => Text(
                            L.t('image_load_error'),
                            style: FontService.style(
                              fontSize: 14,
                              color: onSurf.withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if ((msg['msg_type']?.toString() == 'voice') &&
                      (msg['media']?.toString().isNotEmpty ?? false))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: VoiceMessageBubble(
                        messageKey: key,
                        base64Data: msg['media'].toString(),
                        durationMs: msg['duration_ms'] is int
                            ? msg['duration_ms'] as int
                            : 0,
                        onSurf: onSurf,
                        fontSize: fontSize,
                      ),
                    ),
                  if ((msg['msg_type']?.toString() == 'video') &&
                      (msg['media']?.toString().isNotEmpty ?? false))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: VideoMessageBubble(
                        base64Data: msg['media'].toString(),
                        messageKey: msg['key']?.toString() ?? key,
                        size: _videoBubbleSize(context),
                      ),
                    ),
                  if (text.isNotEmpty)
                    Text(
                      text,
                      style: FontService.style(
                        color: onSurf,
                        fontSize: fontSize,
                      ),
                    ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        () {
                          final st = msg['status']?.toString() ?? '';
                          final pending =
                              msg['pending'] == true || st == 'pending';
                          if (pending) return L.t('waiting_p2p');
                          if (st == 'error') return L.t('error');
                          if (isP2P) return L.t('p2p_connected');
                          return L.t('via_server');
                        }(),
                        style: FontService.style(
                          color: onSurf.withValues(alpha: 0.35),
                          fontSize: 10,
                        ),
                      ),
                      Text(
                        ' · ${_fmtTime(ts)}',
                        style: FontService.style(
                          color: onSurf.withValues(alpha: 0.3),
                          fontSize: 10,
                        ),
                      ),
                      if (rem != null && !isSavedChat && selectedTime > 0)
                        Text(
                          ' · ${rem}s',
                          style: FontService.style(
                            color: onSurf.withValues(alpha: 0.4),
                            fontSize: 10,
                          ),
                        ),
                      if (((msg['ttl'] as int?) ?? 0) == 0)
                        Text(
                          ' · ∞',
                          style: FontService.style(
                            color: onSurf.withValues(alpha: 0.3),
                            fontSize: 10,
                          ),
                        ),
                      const SizedBox(width: 4),
                      _statusIcon(msg, onSurf.withValues(alpha: 0.4)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );

        if (isMe) {
          return Dismissible(
            key: Key(key),
            direction: DismissDirection.endToStart,
            onDismissed: (_) => onSwipeDelete(key),
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              child: Icon(AppIcons.wipe, color: Colors.redAccent),
            ),
            child: bubble,
          );
        }
        return bubble;
      },
    );
  }
}