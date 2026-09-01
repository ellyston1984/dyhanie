import 'dart:async';
import '../unread_chats_service.dart';
import 'app_icon_badge.dart';

class AppBadgeAggregator {
  AppBadgeAggregator._();
  static final instance = AppBadgeAggregator._();

  int _chats = 0;
  int _contacts = 0;
  StreamSubscription? _sub;
  bool _started = false;

  int get total => _chats + _contacts;

  void start() {
    if (_started) return;
    _started = true;
    _chats = UnreadChatsService.instance.dialogCount;
    _sub = UnreadChatsService.instance.changes.listen((_) {
      _chats = UnreadChatsService.instance.dialogCount;
      unawaited(_sync());
    });
    unawaited(_sync());
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _started = false;
  }

  void setContactsBadge(int n) {
    _contacts = n < 0 ? 0 : n;
    unawaited(_sync());
  }

  void setChatsBadge(int n) {
    _chats = n < 0 ? 0 : n;
    unawaited(_sync());
  }

  Future<void> _sync() => AppIconBadge.instance.setCount(total);

  Future<void> clearAll() async {
    _chats = 0;
    _contacts = 0;
    await AppIconBadge.instance.clear();
  }
}