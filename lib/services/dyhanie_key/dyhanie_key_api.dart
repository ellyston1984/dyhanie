enum SessionState {
  none,
  handshaking,
  active,
  idle,
  destroyed,
}

abstract class DyhanieKeyApi {
  /// 6 слов BIP-39 (64 бита энтропии + контрольная сумма).
  Future<List<String>> generateRecoveryPhrase();

  Future<bool> restoreFromPhrase(List<String> words);

  /// 60 цифр Safety Number.
  Future<String> safetyNumber({
    required String localId,
    required String remoteId,
  });

  Future<SessionState> currentSessionState(String peerId);

  Future<void> destroySession(String peerId);

  Future<SessionState> simulateHandshake(String peerId);
}
