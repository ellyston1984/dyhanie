import '../unread_chats_service.dart';

<<<<<<< HEAD
/// data-push → локальные бейджи / unread
=======
>>>>>>> f1159a9 (Push, incoming call launch, locale, avatar cache, related lib updates)
class PushMessageHandler {
  PushMessageHandler._();
  static final instance = PushMessageHandler._();

  Future<void> handle(Map<String, dynamic> data) async {
    final type = (data['type'] ?? '').toString();
    final room = (data['room'] ?? '').toString();
    final badge = int.tryParse('${data['badge']}') ?? 1;

    switch (type) {
      case 'chat.nudge':
      case 'msg':
      case 'badge':
        if (room.isNotEmpty) {
          await UnreadChatsService.instance.add(room, badge < 1 ? 1 : badge);
        }
        break;
<<<<<<< HEAD
      case 'contact.invite':
        // Home сам обновит contactsBadge после refresh invites
        break;
      case 'call_offer':
        // SystemIncomingCall / CallKit / FCM full-screen — отдельно
=======
      default:
>>>>>>> f1159a9 (Push, incoming call launch, locale, avatar cache, related lib updates)
        break;
    }
  }
}