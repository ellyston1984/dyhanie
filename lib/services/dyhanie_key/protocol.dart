class DyhanieProtocol {
  static const int version = 1;
  static const int cipherSuite = 1; // ChaCha20-Poly1305
  static const int wordCount = 6;
  static const int entropyBytes = 8; // 64 bit + 2 checksum bits → 6×11
  static const int maxSkipped = 128;
  static const int headerSize = 64;
  static const int macSize = 16;
  static const int nonceSize = 12;
  static const int identityPackSize = 64;

  static const handshakeTimeout = Duration(seconds: 15);
  static const handshakeReplyTimeout = Duration(seconds: 10);
  static const idleTimeout = Duration(hours: 1);

  static const List<int> padBaskets = <int>[256, 512, 1024, 2048, 4096];

  static const int pktHandshake = 0x10;
  static const int pktConfirm = 0x11;
  static const int pktApp = 0x20;

  static const int contentText = 0x01;
  static const int contentCover = 0x00;

  static const String infoIdentitySeed = 'DyhanieIdentitySeed';
  static const String infoX25519 = 'DyhanieX25519';
  static const String infoEd25519 = 'DyhanieEd25519';
  static const String infoHandshakeRoot = 'P2PHandshakeRoot';
  static const String infoConfirm = 'SessionConfirmation';
  static const String infoChainAlice = 'DyhanieChainAlice';
  static const String infoChainBob = 'DyhanieChainBob';
  static const String infoCk = 'DyhanieCK';
  static const String infoMk = 'DyhanieMK';
  static const String infoRoot = 'DyhanieRoot';
}
