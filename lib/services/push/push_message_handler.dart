import '../unread_chats_service.dart';

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
      case 'contact.invite':
        break;
      case 'call_offer':
      default:
        break;
    }
  }
}