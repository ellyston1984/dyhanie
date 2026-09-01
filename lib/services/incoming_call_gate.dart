class IncomingCallGate {
  IncomingCallGate._();
  static final instance = IncomingCallGate._();

  String? _activeKey;
  DateTime? _until;

  bool tryLock(String room, String from) {
    final key = '${room.toLowerCase()}|${from.toLowerCase()}';
    final now = DateTime.now();
    if (_activeKey == key && _until != null && now.isBefore(_until!)) {
      return false;
    }
    _activeKey = key;
    _until = now.add(const Duration(seconds: 20));
    return true;
  }

  void unlock() {
    _activeKey = null;
    _until = null;
  }
}