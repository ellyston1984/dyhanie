import 'dart:async';


/// Заглушка: dialog-сигналы больше не через Firebase.
class DialogSignalService {
  Future<void> setPendingIn({
    required String from,
    required String to,
    required int count,
  }) async {}

  Future<void> clearPendingIn({
    required String from,
    required String to,
  }) async {}

  Future<void> requestPull({
    required String myUsername,
    required String otherUser,
  }) async {}

  Future<void> clearPull({
    required String myUsername,
    required String otherUser,
  }) async {}

  Future<void> setComeOnline({
    required String from,
    required String to,
  }) async {}

  Future<void> clearComeOnline({
    required String forUser,
    required String otherUser,
  }) async {}

  Future<void> setDeliveredAck({
    required String from,
    required String to,
  }) async {}

  StreamSubscription listenMySignals({
    required String myUsername,
    required void Function(Map<String, Map<String, dynamic>> signalsByDialog)
        onSignals,
  }) {
    scheduleMicrotask(() => onSignals({}));
    return const Stream<void>.empty().listen((_) {});
  }

  StreamSubscription listenPull({
    required String dialogId,
    required String otherUser,
    required void Function(Map data) onPull,
  }) {
    return const Stream<void>.empty().listen((_) {});
  }

  Future<void> publishDelivery({
    required String dialogId,
    required String toUser,
    required List<Map<String, dynamic>> messages,
  }) async {}

  StreamSubscription listenDelivery({
    required String dialogId,
    required String myUsername,
    required void Function(List<Map<String, dynamic>> messages) onMessages,
  }) {
    return const Stream<void>.empty().listen((_) {});
  }

  Future<void> setDialogPresence({
    required String dialogId,
    required String username,
    required bool online,
  }) async {}

  StreamSubscription listenDialogPresence({
    required String dialogId,
    required String otherUser,
    required void Function(bool online) onChanged,
  }) {
    onChanged(false);
    return const Stream<void>.empty().listen((_) {});
  }
}