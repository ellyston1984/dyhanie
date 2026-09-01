import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_compress/video_compress.dart';

import '../compat/local_fs.dart';
import '../services/chat_history_service.dart';
import '../services/dialog_signal_service.dart';
import '../services/font_service.dart';
import '../services/locale_service.dart';
import '../services/p2p_service.dart';
import '../services/dyhanie_api.dart';
import '../services/unread_chats_service.dart';
import '../services/avatar_cache.dart';
import '../services/icon_style_service.dart';
import '../services/incoming_call_service.dart';
import '../services/contact_invite_service.dart';
import '../services/media_message_cache.dart';
import '../services/media_chunk_assembler.dart';
import '../services/transport_mode_service.dart';
import '../services/message_send_service.dart';

import '../widgets/chat_app_bar.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/chat_message_list.dart';
import '../widgets/chat_media_strip.dart';
import '../widgets/video_capture_overlay.dart';

import 'call_screen.dart';
import 'emoji_picker_screen.dart';

class ChatScreen extends StatefulWidget {
  final String roomCode;
  final String username;

  const ChatScreen({
    super.key,
    required this.roomCode,
    required this.username,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _controller = TextEditingController();
  final _searchCtrl = TextEditingController();
  final _picker = ImagePicker();
  final _scroll = ScrollController();
  final _dialogSignals = DialogSignalService();
  final _history = ChatHistoryService();
  final _audioRecorder = AudioRecorder();

  String? _mediaRecordPath;
  DateTime? _mediaRecordStarted;
  bool _mediaActuallyRecording = false;
  bool _showVideoOverlay = false;
  final _videoOverlayKey = GlobalKey<VideoCaptureOverlayState>();
  bool _micReady = false;
  StreamSubscription? _presenceSub;

  Timer? _presenceTimer;
  bool _presenceBusy = false;
  DateTime? _lastPeerPresenceAt;

  List<Map<String, dynamic>> messages = [];
  final _timers = <String, Timer>{};
  final _remaining = <String, int>{};
  final _knownServerKeys = <String>{};

  StreamSubscription? _p2pMsgSub;
  StreamSubscription? _p2pStatusSub;
  StreamSubscription? _apiMsgSub;
  StreamSubscription? _callSignalSub;
  bool _openingCall = false;

  P2PService? _p2p;
  bool p2pConnected = false;
  String p2pStatusText = '';
  String connectionMode = '';

  bool get blockServerMessages => TransportModeService.instance.isP2p;

  int selectedTime = 0;
  bool wipeOnExit = false;

  double messageFontSize = 16;

  /// 0=XS … 4=XL — масштаб пузырей и шрифта в ленте
  int messageSizeLevel = 2;

  static const List<double> messageSizeScales = [
    0.75,
    0.90,
    1.00,
    1.15,
    1.35,
  ];

  double get messageSizeScale =>
      messageSizeScales[messageSizeLevel.clamp(0, 4)];

  Uint8List? backgroundBytes;
  Uint8List? myAvatarBytes;
  Uint8List? otherAvatarBytes;
  String? typingUser;
  bool isSavedChat = false;
  bool saveRequestIncoming = false;
  String? saveRequestedBy;
  String? otherUser;
  bool otherOnline = false;
  bool showSearch = false;
  String searchQuery = '';
  Map<String, dynamic>? pinned;
  Map<String, dynamic>? replyTo;
  int? otherLastRead;
  bool callInProgress = false;
  String callStatusBanner = '';

  final timeOptions = [0, 5, 10, 15, 30, 60, 120, 300, 600];

  bool _looksLikeDirectDialog(String code) {
    return code.contains('_') && code.length > 6;
  }

  String? _otherFromRoomCode() {
    if (!_looksLikeDirectDialog(widget.roomCode)) return null;
    final me = widget.username.toLowerCase().trim();
    final code = widget.roomCode.toLowerCase().trim();
    final parts = code.split('_');
    if (parts.length == 2) {
      if (parts[0] == me) return parts[1];
      if (parts[1] == me) return parts[0];
      return null;
    }
    if (code.startsWith('${me}_')) return code.substring(me.length + 1);
    if (code.endsWith('_$me')) {
      return code.substring(0, code.length - me.length - 1);
    }
    return otherUser?.toLowerCase().trim();
  }

  Future<void> _loadAvatars() async {
    final prefs = await SharedPreferences.getInstance();

    Uint8List? mine;
    final myRaw = prefs.getString('avatar');
    if (myRaw != null && myRaw.isNotEmpty) {
      try {
        final clean = myRaw.contains(',') ? myRaw.split(',').last : myRaw;
        mine = base64Decode(clean);
      } catch (_) {}
    }

    Uint8List? otherBytes;
    final other = otherUser ?? _otherFromRoomCode();
    if (other != null && other.isNotEmpty) {
      otherBytes = await AvatarCache.fetch(
        other,
        forceNetwork: true,
        bindUsername: widget.username,
      );
    }

    if (!mounted) return;
    setState(() {
      myAvatarBytes = mine;
      otherAvatarBytes = otherBytes;
    });
  }

  String get _prefsPrefix => 'chat_cfg_${widget.roomCode}_';

  Future<void> _loadChatConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final p = _prefsPrefix;
    if (!mounted) return;
    setState(() {
      wipeOnExit = prefs.getBool('${p}wipe') ?? false;
      selectedTime = prefs.getInt('${p}ttl') ?? 0;
      messageFontSize = prefs.getDouble('${p}font') ?? 16.0;
      messageSizeLevel = prefs.getInt('${p}msg_size') ?? 2;
    });
    _updateConnectionMode();
  }

  Future<void> _saveChatConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final p = _prefsPrefix;
    await prefs.setBool('${p}wipe', wipeOnExit);
    await prefs.setInt('${p}ttl', selectedTime);
    await prefs.setDouble('${p}font', messageFontSize);
    await prefs.setInt('${p}msg_size', messageSizeLevel);
  }

  Future<void> _clearMyIncomingSignal() async {
    if (!_looksLikeDirectDialog(widget.roomCode)) return;
    final other = _otherFromRoomCode();
    if (other == null) return;
    try {
      await _dialogSignals.clearPendingIn(from: other, to: widget.username);
    } catch (_) {}
  }

  Future<void> _loadSavedHistory() async {
    try {
      final saved = await _history.load(widget.roomCode);
      if (!mounted || saved.isEmpty) return;

      await _hydrateMedia(saved);
      if (!mounted) return;

      setState(() {
        final existingKeys = messages.map((m) => m['key']?.toString()).toSet();
        for (final m in saved) {
          final key = m['key']?.toString();
          if (key == null || existingKeys.contains(key)) continue;
          messages.add(m);
          _knownServerKeys.add(key);
        }
        messages.sort((a, b) {
          final ta = a['timestamp'] as int? ?? 0;
          final tb = b['timestamp'] as int? ?? 0;
          return ta.compareTo(tb);
        });
      });
      _scrollEnd();
    } catch (_) {}
    // pending retry убран вместе с send-orchestration
  }

  Future<void> _persistMediaForMessage(Map<String, dynamic> msg) async {
    final key = msg['key']?.toString() ?? '';
    final media = msg['media']?.toString();
    if (key.isEmpty || media == null || media.isEmpty) return;
    if (msg['media_path'] != null &&
        msg['media_path'].toString().isNotEmpty) {
      return;
    }

    final path = await MediaMessageCache.instance.put(
      roomCode: widget.roomCode,
      msgKey: key,
      base64Data: media,
      msgType: msg['msg_type']?.toString(),
      mime: msg['mime']?.toString(),
    );
    if (path != null) {
      msg['media_path'] = path;
    }
  }

  Future<void> _hydrateMedia(List<Map<String, dynamic>> list) async {
    for (final m in list) {
      final existing = m['media']?.toString();
      if (existing != null && existing.isNotEmpty) continue;

      final path = m['media_path']?.toString();
      final b64 = await MediaMessageCache.instance.getBase64(path);
      if (b64 != null) {
        m['media'] = b64;
      }
    }
  }

  Future<void> _saveHistory() async {
    if (wipeOnExit) return;
    for (final m in messages) {
      await _persistMediaForMessage(m);
    }
    await _history.save(widget.roomCode, messages);
  }

  Future<void> _notifyDirectIncoming() async {
    final other = (_otherFromRoomCode() ?? otherUser)?.toLowerCase().trim();
    if (other == null || other.isEmpty) return;
    if (!_looksLikeDirectDialog(widget.roomCode)) return;

    try {
      await _dialogSignals.setPendingIn(
        from: widget.username,
        to: other,
        count: 1,
      );
    } catch (_) {}

    try {
      final api = DyhanieApi.instance;
      if (!api.isConnected) await api.connect();
      final me = widget.username.toLowerCase().trim();
      if (api.boundUsername?.toLowerCase() != me) {
        await api.sessionBind(me);
      }
      await api.chatNudge(to: other, room: widget.roomCode);
    } catch (_) {}
  }

  Future<void> _bootstrapPeer() async {
    final other = _otherFromRoomCode();
    if (other == null || other.isEmpty) return;
    if (!mounted) return;
    setState(() {
      otherUser = other;
      otherOnline = false;
    });
    _updateConnectionMode();
    await _loadAvatars();

    final prefs = await SharedPreferences.getInstance();
    final contacts = prefs.getStringList('contacts') ?? [];
    if (!contacts.contains(other)) {
      contacts.add(other);
      await prefs.setStringList('contacts', contacts);
    }

    await _syncServerMessages();
    // _flushPending убран
    await UnreadChatsService.instance.clear(widget.roomCode);
    DyhanieApi.instance.chatNudgeAck(room: widget.roomCode).catchError((_) {});

    if (!mounted) return;
    _startPresencePolling();
    if (TransportModeService.instance.isP2p) {
      await _startP2P(other);
    }
    await _clearMyIncomingSignal();
    await _announceInChat(true);
  }

  void _startPresencePolling() {
    _presenceTimer?.cancel();
    final peer = (otherUser ?? _otherFromRoomCode())?.toLowerCase().trim();
    if (peer == null || peer.isEmpty) return;

    unawaited(_tickPresence(peer));

    _presenceTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_tickPresence(peer));
    });
  }

  Future<void> _tickPresence(String peer) async {
    if (_presenceBusy || !mounted) return;
    _presenceBusy = true;
    try {
      final api = DyhanieApi.instance;

      try {
        if (!api.isConnected) await api.connect();
        final me = widget.username.toLowerCase().trim();
        if (api.boundUsername?.toLowerCase() != me) {
          await api.sessionBind(me);
        }
      } catch (_) {
        if (mounted && otherOnline) {
          setState(() => otherOnline = false);
        }
        return;
      }

      await api.chatPresence(room: widget.roomCode, inside: true);
      unawaited(_announceInChat(true));

      var online = await api.chatPresenceQuery(
        room: widget.roomCode,
        peer: peer,
      );

      if (!online &&
          _lastPeerPresenceAt != null &&
          DateTime.now().difference(_lastPeerPresenceAt!) <
              const Duration(seconds: 4)) {
        online = true;
      }

      if (!mounted) return;
      if (otherOnline != online) {
        setState(() => otherOnline = online);
      }
    } catch (_) {
      if (mounted && otherOnline) {
        setState(() => otherOnline = false);
      }
    } finally {
      _presenceBusy = false;
    }
  }

  void _stopPresencePolling() {
    _presenceTimer?.cancel();
    _presenceTimer = null;
    DyhanieApi.instance
        .chatPresence(room: widget.roomCode, inside: false)
        .catchError((_) {});
  }

  Future<void> _announceInChat(bool inside) async {
    final other = (otherUser ?? _otherFromRoomCode())?.toLowerCase().trim();
    if (other == null || other.isEmpty) return;
    try {
      final api = DyhanieApi.instance;
      if (!api.isConnected) await api.connect();
      final me = widget.username.toLowerCase().trim();
      if (api.boundUsername?.toLowerCase() != me) {
        await api.sessionBind(me);
      }
      await api.signal(
        room: widget.roomCode,
        to: other,
        kind: 'chat_presence',
        data: {'in': inside},
      );
    } catch (_) {}
  }

  Future<void> _ensureMic() async {
    final s = await Permission.microphone.status;
    if (s.isGranted) {
      _micReady = true;
      return;
    }
    final r = await Permission.microphone.request();
    _micReady = r.isGranted;
    if (!_micReady && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нужен доступ к микрофону')),
      );
    }
  }

  void _enqueueOutgoing(Map<String, dynamic> msg) {
    if (mounted) {
      setState(() {
        messages = [...messages, msg];
        replyTo = null;
      });
    }
    if (!isSavedChat && selectedTime > 0) _startTimer(msg);
    _scrollEnd();
    HapticFeedback.lightImpact();

    unawaited(
      MessageSendService.instance.deliverWithRetry(
        msg: msg,
        roomCode: widget.roomCode,
        myUsername: widget.username,
        otherUser: otherUser ?? _otherFromRoomCode(),
        p2p: _p2p,
        isP2pOpen: () => p2pConnected && _p2p != null && _p2p!.isOpen,
        onSent: (updated) {
          if (!mounted) return;
          setState(() {
            final i = messages.indexWhere((m) => m['key'] == updated['key']);
            if (i >= 0) {
              messages[i]['status'] = 'sent';
              messages[i]['pending'] = false;
              messages[i]['p2p'] = updated['p2p'];
            }
          });
          if (!wipeOnExit) unawaited(_saveHistory());
        },
      ),
    );
    unawaited(_notifyDirectIncoming());
  }

  void _listenServerMessages() {
    _apiMsgSub?.cancel();
    _apiMsgSub = DyhanieApi.instance.events.listen((m) async {
      if (m['type']?.toString() != 'msg.incoming') return;
      final p = m['payload'];
      if (p is! Map) return;
      await _ingestServerMsg(Map<String, dynamic>.from(p));
    });
  }

  Future<void> _syncServerMessages() async {
    if (blockServerMessages) return;
    try {
      if (!DyhanieApi.instance.isConnected) {
        await DyhanieApi.instance.connect();
      }

      final list = await DyhanieApi.instance.msgSync();
      final forRoom = list.where((p) {
        return (p['room']?.toString() ?? '') == widget.roomCode;
      }).toList();

      forRoom.sort((a, b) {
        final ta = a['created_at'] is int ? a['created_at'] as int : 0;
        final tb = b['created_at'] is int ? b['created_at'] as int : 0;
        return ta.compareTo(tb);
      });

      for (final p in forRoom) {
        unawaited(_ingestServerMsg(p));
      }
      if (mounted) _scrollEnd();
    } catch (_) {}
  }

  Future<void> _ingestServerMsg(Map p) async {
    if (blockServerMessages) return;

    final msgId = p['msg_id']?.toString() ?? '';
    if (msgId.isEmpty) return;

    if (_knownServerKeys.contains(msgId)) {
      DyhanieApi.instance.msgAckRead(msgId).catchError((_) {});
      return;
    }

    final room = p['room']?.toString() ?? '';
    if (room != widget.roomCode) return;

    final from = p['from']?.toString() ?? '';
    if (from.isEmpty || from == widget.username) return;

    if (await ContactInviteService().isBlocked(from)) return;

    final body = p['body']?.toString() ?? '';
    final contentType = p['content_type']?.toString() ?? 'text';

    if (contentType == 'media_chunk' ||
        (body.startsWith('{') && body.contains('"media_chunk"'))) {
      try {
        final j = jsonDecode(body) as Map<String, dynamic>;
        if (j['type']?.toString() == 'media_chunk') {
          j['from'] = from;
          final done =
              MediaChunkAssembler.instance.add(Map<String, dynamic>.from(j));
          DyhanieApi.instance.msgAckRead(msgId).catchError((_) {});
          if (done != null) {
            if ((done['username']?.toString() ?? '').isEmpty) {
              done['username'] = from;
            }
            final doneKey = done['key']?.toString() ?? msgId;
            if (!_knownServerKeys.contains(doneKey) &&
                !messages.any((m) => m['key']?.toString() == doneKey)) {
              _knownServerKeys.add(doneKey);
              await _persistMediaForMessage(done);
              if (!mounted) return;
              setState(() => messages = [...messages, done]);
              final ttl = done['ttl'] is int ? done['ttl'] as int : 0;
              if (!isSavedChat && ttl > 0) _startTimer(done);
              _scrollEnd();
              UnreadChatsService.instance.clear(widget.roomCode);
              if (!wipeOnExit) await _saveHistory();
            }
          }
          return;
        }
      } catch (_) {}
    }

    String text = body;
    String? image;
    String? media;
    String msgType = 'text';
    int? durationMs;
    String? replyText;
    String? replyUser;
    int ttl = selectedTime;

    try {
      if (body.startsWith('{')) {
        final j = jsonDecode(body) as Map<String, dynamic>;
        if (j['type']?.toString() == 'media_chunk') return;
        text = j['text']?.toString() ?? '';
        image = j['image']?.toString();
        media = j['media']?.toString();
        msgType = j['msg_type']?.toString() ?? 'text';
        durationMs =
            j['duration_ms'] is int ? j['duration_ms'] as int : null;
        replyText = j['replyText']?.toString();
        replyUser = j['replyUser']?.toString();
        if (j['ttl'] is int) ttl = j['ttl'] as int;
      }
    } catch (_) {}

    final msg = <String, dynamic>{
      'key': msgId,
      'text': text,
      'username': from,
      'timestamp': p['created_at'] is int
          ? p['created_at'] as int
          : DateTime.now().millisecondsSinceEpoch,
      'ttl': ttl,
      'p2p': false,
      'replyText': replyText,
      'replyUser': replyUser,
      'image': image,
      'media': media,
      'msg_type': msgType,
      'duration_ms': durationMs,
      'status': 'delivered',
    };

    _knownServerKeys.add(msgId);
    await _persistMediaForMessage(msg);

    if (!mounted) return;
    setState(() => messages = [...messages, msg]);
    if (!isSavedChat && ttl > 0) _startTimer(msg);
    _scrollEnd();

    DyhanieApi.instance.msgAckRead(msgId).catchError((_) {});
    UnreadChatsService.instance.clear(widget.roomCode);
    if (!wipeOnExit) await _saveHistory();
  }

  Future<void> _startP2P(String other) async {
    if (_p2p != null) return;

    _p2p = P2PService(
      roomCode: widget.roomCode,
      username: widget.username,
      otherUser: other,
    );

    _p2pStatusSub?.cancel();
    _p2pStatusSub = _p2p!.status.listen((s) {
      if (mounted) setState(() => p2pStatusText = s);

      if (s == 'p2p_open') {
        if (mounted) {
          setState(() => p2pConnected = true);
          _updateConnectionMode();
          _saveChatConfig();
        }
        // _flushPending убран
        return;
      }

      final bad = s == 'need_restart' ||
          s == 'ice_failed' ||
          s.contains('failed') ||
          s.contains('Failed') ||
          s.contains('closed') ||
          s.contains('Closed');
      if (!bad) return;
      if (s == 'need_restart' && p2pConnected) return;

      if (mounted) {
        setState(() => p2pConnected = false);
        _updateConnectionMode();
        _saveChatConfig();
      }

      _p2pMsgSub?.cancel();
      _p2pStatusSub?.cancel();
      final old = _p2p;
      _p2p = null;
      old?.dispose();

      Future.delayed(const Duration(seconds: 2), () {
        if (!mounted || otherUser == null || _p2p != null) return;
        if (!TransportModeService.instance.isP2p) return;
        _startP2P(otherUser!);
      });
    });

    _p2pMsgSub?.cancel();
    _p2pMsgSub = _p2p!.messages.listen((raw) {
      try {
        if (raw.startsWith('{')) {
          final data = jsonDecode(raw) as Map<String, dynamic>;

          if (data['type'] == 'clear_chat') {
            for (final t in _timers.values) {
              t.cancel();
            }
            _timers.clear();
            _remaining.clear();
            if (mounted) setState(() => messages = []);
            return;
          }
          if (data['type'] == 'delete') {
            _removeLocal(data['key']?.toString() ?? '');
            return;
          }
          if (data['type'] == 'media_chunk') {
            unawaited(_handleIncomingMediaChunk(data, other, viaP2p: true));
            return;
          }
          if (data['type'] == 'msg') {
            _addIncomingP2P(data, other);
            return;
          }
        }
      } catch (_) {}
      _addIncomingP2P({'text': raw, 'ttl': selectedTime}, other);
    });

    try {
      await _p2p!.connect();
    } catch (e) {
      if (mounted) setState(() => p2pStatusText = '${L.t('error')}: $e');
    }
  }

  void _addIncomingP2P(Map data, String other) {
    final key = data['key']?.toString() ??
        'p2p_${DateTime.now().millisecondsSinceEpoch}';
    if (messages.any((m) => m['key']?.toString() == key)) return;

    final msg = {
      'key': key,
      'text': data['text']?.toString() ?? '',
      'username': other,
      'timestamp': data['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
      'ttl': data['ttl'] ?? selectedTime,
      'p2p': true,
      'replyText': data['replyText'],
      'replyUser': data['replyUser'],
      'image': data['image'],
      'status': 'delivered',
      'media': data['media'],
      'msg_type': data['msg_type'] ?? 'text',
      'duration_ms': data['duration_ms'],
      'mime': data['mime'],
    };
    if (!mounted) return;
    setState(() => messages = [...messages, msg]);
    final ttl = msg['ttl'] is int
        ? msg['ttl'] as int
        : int.tryParse('${msg['ttl']}') ?? 0;
    if (!isSavedChat && ttl > 0) _startTimer(msg);
    HapticFeedback.mediumImpact();
    SystemSound.play(SystemSoundType.click);
    _scrollEnd();
    _clearMyIncomingSignal();
  }

  Future<void> _handleIncomingMediaChunk(
    Map data,
    String other, {
    required bool viaP2p,
  }) async {
    final map = Map<String, dynamic>.from(data);
    if ((map['from']?.toString() ?? '').isEmpty) {
      map['from'] = other;
    }

    final done = MediaChunkAssembler.instance.add(map);
    if (done == null) return;

    final key = done['key']?.toString() ?? '';
    if (key.isEmpty) return;
    if (_knownServerKeys.contains(key)) return;
    if (messages.any((m) => m['key']?.toString() == key)) return;

    done['username'] = (done['username']?.toString().isNotEmpty ?? false)
        ? done['username']
        : other;
    done['p2p'] = viaP2p;
    done['status'] = 'delivered';

    _knownServerKeys.add(key);
    await _persistMediaForMessage(done);

    if (!mounted) return;
    setState(() => messages = [...messages, done]);

    final ttl = done['ttl'] is int ? done['ttl'] as int : 0;
    if (!isSavedChat && ttl > 0) _startTimer(done);

    HapticFeedback.mediumImpact();
    _scrollEnd();
    _clearMyIncomingSignal();
    if (!wipeOnExit) await _saveHistory();
  }

  // ---------------------------------------------------------------------------
  // Media capture (без отправки)
  // ---------------------------------------------------------------------------

  Future<void> _onMediaRecordStart(MediaStripMode mode) async {
    if (mode == MediaStripMode.video) {
      final cam = await Permission.camera.request();
      final mic = await Permission.microphone.request();
      if (!cam.isGranted || !mic.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Нужны камера и микрофон')),
          );
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        _showVideoOverlay = true;
      });
      return;
    }

    if (!_micReady) {
      await _ensureMic();
      if (!_micReady) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Микрофон разрешён. Зажмите полоску ещё раз'),
          ),
        );
      }
      return;
    }

    try {
      if (await _audioRecorder.isRecording()) {
        await _audioRecorder.stop();
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 32000,
          sampleRate: 22050,
        ),
        path: path,
      );
      _mediaRecordPath = path;
      _mediaRecordStarted = DateTime.now();
      _mediaActuallyRecording = true;
    } catch (e) {
      _mediaActuallyRecording = false;
      _mediaRecordPath = null;
      _mediaRecordStarted = null;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Старт записи: $e')),
        );
      }
    }
  }

  Future<void> _onVideoFileReady(String path, int durationMs) async {
    if (mounted) {
      setState(() {
        _showVideoOverlay = false;
      });
    }

    try {
      final info = await VideoCompress.compressVideo(
        path,
        quality: VideoQuality.LowQuality,
        deleteOrigin: false,
        includeAudio: true,
      );

      final out = info?.path;
      if (out == null || out.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Не удалось сжать видео')),
          );
        }
        return;
      }

      final bytes = await readFileBytes(out) ?? Uint8List(0);
      if (bytes.isEmpty || bytes.length < 1000) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Видео файл пуст')),
          );
        }
        return;
      }
      if (bytes.length > 4 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L.t('file_too_big'))),
          );
        }
        return;
      }

      final rawDuration = info?.duration;
      final int ms = rawDuration == null
          ? durationMs
          : rawDuration.round().clamp(0, 20000);
      
      final msg = MessageSendService.instance.buildMediaMessage(
        myUsername: widget.username,
        msgType: 'video',
        mediaBase64: base64Encode(bytes),
        mime: 'video/mp4',
        durationMs: ms,
        ttlSeconds: selectedTime,
        replyTo: replyTo,
      );
      await _persistMediaForMessage(msg);
      if (!wipeOnExit) await _saveHistory();
      _enqueueOutgoing(msg);
     
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Видео: $e')),
        );
      }
    } finally {
      await deleteFilePath(path);
      try {
        await VideoCompress.deleteAllCache();
      } catch (_) {}
    }
  }

  Future<void> _onMediaRecordEnd(MediaStripMode mode) async {
    if (mode == MediaStripMode.video) {
      await _videoOverlayKey.currentState?.stopRecording(send: true);
      return;
    }

    if (!_mediaActuallyRecording) return;
    _mediaActuallyRecording = false;

    String? path;
    try {
      path = await _audioRecorder.stop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Стоп записи: $e')),
        );
      }
      _mediaRecordPath = null;
      _mediaRecordStarted = null;
      return;
    }

    path ??= _mediaRecordPath;
    final started = _mediaRecordStarted;
    _mediaRecordPath = null;
    _mediaRecordStarted = null;

    if (path == null || path.isEmpty) return;

    final ms = started == null
        ? 0
        : DateTime.now().difference(started).inMilliseconds;

    if (ms < 400) {
      await deleteFilePath(path);
      return;
    }

    if (!await fileExists(path)) return;

    final bytes = await readFileBytes(path) ?? Uint8List(0);
    await deleteFilePath(path);

    if (bytes.isEmpty || bytes.length > 500000) {
      if (mounted && bytes.length > 500000) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L.t('file_too_big'))),
        );
      }
      return;
    }
    final msg = MessageSendService.instance.buildMediaMessage(
      myUsername: widget.username,
      msgType: 'voice',
      mediaBase64: base64Encode(bytes),
      mime: 'audio/m4a',
      durationMs: ms.clamp(0, 60000),
      ttlSeconds: selectedTime,
      replyTo: replyTo,
    );
    await _persistMediaForMessage(msg);
    if (!wipeOnExit) await _saveHistory();
    _enqueueOutgoing(msg);

  }

  Future<void> _onSendPressed() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    final msg = MessageSendService.instance.buildTextMessage(
      myUsername: widget.username,
      text: text,
      ttlSeconds: selectedTime,
      replyTo: replyTo,
    );
    _controller.clear();
    _enqueueOutgoing(msg);
  }

  Future<void> _onMediaRecordCancel(MediaStripMode mode) async {
    if (mode == MediaStripMode.video) {
      await _videoOverlayKey.currentState?.stopRecording(send: false);
      if (mounted) {
        setState(() {
          _showVideoOverlay = false;
        });
      }
      return;
    }

    _mediaActuallyRecording = false;
    try {
      if (await _audioRecorder.isRecording()) {
        await _audioRecorder.stop();
      }
    } catch (_) {}
    final p = _mediaRecordPath;
    _mediaRecordPath = null;
    _mediaRecordStarted = null;
    if (p != null) {
      await deleteFilePath(p);
    }
  }

  Future<void> _attach() async {
    final img = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      imageQuality: 70,
    );
    if (img == null) return;
    final bytes = await img.readAsBytes();
    if (bytes.length > 600000) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L.t('file_too_big'))),
        );
      }
      return;
    }
    final msg = MessageSendService.instance.buildMediaMessage(
      myUsername: widget.username,
      msgType: 'image',
      mediaBase64: base64Encode(bytes),
      mime: 'image/jpeg',
      ttlSeconds: selectedTime,
      replyTo: replyTo,
    );
    _enqueueOutgoing(msg);
  }

  Future<void> _openEmoji() async {
    final emoji = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const EmojiPickerScreen()),
    );
    if (emoji == null || !mounted) return;
    final text = _controller.text;
    final sel = _controller.selection;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final next = text.replaceRange(start, end, emoji);
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
  }

  Future<void> _shareHistory() async {
    // P2P-рассылка истории — тоже send-path; отключено до нового сервиса
    
  }

  void _startTimer(Map<String, dynamic> msg) {
    if (isSavedChat) return;
    final key = msg['key']?.toString() ?? '';
    if (key.isEmpty) return;
    final ttl = msg['ttl'] is int
        ? msg['ttl'] as int
        : int.tryParse('${msg['ttl']}') ?? 0;
    if (ttl <= 0) return;

    final created = msg['timestamp'] is int
        ? msg['timestamp'] as int
        : int.tryParse('${msg['timestamp']}') ?? 0;
    var remaining =
        ttl - ((DateTime.now().millisecondsSinceEpoch - created) ~/ 1000);
    if (remaining <= 0) {
      _deleteForBoth(key);
      return;
    }

    _remaining[key] = remaining;
    _timers[key]?.cancel();
    _timers[key] = Timer.periodic(const Duration(seconds: 1), (t) {
      remaining--;
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _remaining[key] = remaining);
      if (remaining <= 0) {
        t.cancel();
        _deleteForBoth(key);
      }
    });
  }

  void _pinMessage(Map<String, dynamic> msg) {
    setState(() {
      pinned = {
        'text': msg['text'],
        'username': msg['username'],
        'key': msg['key'],
      };
    });
  }

  void _deleteForBoth(String key) {
    _removeLocal(key);
    if (p2pConnected && _p2p != null) {
      try {
        _p2p!.send(jsonEncode({'type': 'delete', 'key': key}));
      } catch (_) {}
    }
  }

  void _removeLocal(String key) {
    MediaMessageCache.instance.deleteKey(
      roomCode: widget.roomCode,
      msgKey: key,
    );

    _timers[key]?.cancel();
    _timers.remove(key);
    _remaining.remove(key);

    if (!mounted) return;
    setState(() {
      messages = messages.where((m) => m['key']?.toString() != key).toList();
    });
    if (!wipeOnExit) {
      unawaited(_saveHistory());
    }
  }

  void _messageActions(Map<String, dynamic> msg) {
    final scheme = Theme.of(context).colorScheme;
    final onSurf = scheme.onSurface;

    showModalBottomSheet(
      context: context,
      backgroundColor: scheme.surfaceContainerHigh,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading:
                  Icon(AppIcons.reply, color: onSurf.withValues(alpha: 0.7)),
              title:
                  Text(L.t('reply'), style: FontService.style(color: onSurf)),
              onTap: () {
                setState(() => replyTo = msg);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading:
                  Icon(AppIcons.pin, color: onSurf.withValues(alpha: 0.7)),
              title: Text(L.t('pin_message'),
                  style: FontService.style(color: onSurf)),
              onTap: () {
                _pinMessage(msg);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading:
                  Icon(AppIcons.copy, color: onSurf.withValues(alpha: 0.7)),
              title:
                  Text(L.t('copy'), style: FontService.style(color: onSurf)),
              onTap: () {
                Clipboard.setData(
                  ClipboardData(text: msg['text']?.toString() ?? ''),
                );
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(L.t('copied'))),
                );
              },
            ),
            if (msg['username'] == widget.username)
              ListTile(
                leading: Icon(AppIcons.delete, color: Colors.redAccent),
                title: Text(
                  L.t('delete_for_all'),
                  style: const TextStyle(color: Colors.redAccent),
                ),
                onTap: () {
                  _deleteForBoth(msg['key'] as String);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _scrollEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  List<Map<String, dynamic>> get _visibleMessages {
    if (searchQuery.isEmpty) return messages;
    final q = searchQuery.toLowerCase();
    return messages
        .where((m) => (m['text']?.toString() ?? '').toLowerCase().contains(q))
        .toList();
  }

  void _updateConnectionMode() {
    final t = TransportModeService.instance;
    final String mode;
    if (t.isServer) {
      mode = L.t('via_server');
    } else {
      mode = p2pConnected ? 'P2P' : L.t('p2p_only_wait');
    }
    if (mounted) setState(() => connectionMode = mode);
  }

  // ---------------------------------------------------------------------------
  // Calls / presence listeners
  // ---------------------------------------------------------------------------

  void _startCall() {
    final peer = otherUser ?? _otherFromRoomCode();
    if (peer == null || peer.isEmpty) return;
    if (callInProgress || _openingCall) return;

    setState(() {
      otherUser = peer;
      callInProgress = true;
      callStatusBanner = L.t('call_calling');
    });

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CallScreen(
          roomCode: widget.roomCode,
          username: widget.username,
          otherUser: peer,
          isIncoming: false,
        ),
      ),
    ).then((_) {
      if (!mounted) return;
      setState(() {
        callInProgress = false;
        callStatusBanner = '';
      });
    });
  }

  void _listenIncomingCalls() {
    _callSignalSub?.cancel();
    _callSignalSub = DyhanieApi.instance.events.listen((m) {
      if (m['type']?.toString() != 'signal') return;
      final p = m['payload'];
      if (p is! Map) return;

      final room = (p['room']?.toString() ?? '').toLowerCase().trim();
      if (room != widget.roomCode.toLowerCase().trim()) return;

      final from = (p['from']?.toString() ?? '').toLowerCase().trim();
      if (from.isEmpty || from == widget.username.toLowerCase().trim()) return;

      final kind = p['kind']?.toString() ?? '';
      if (kind != 'call_offer') return;
      if (callInProgress || _openingCall) return;

      final data = p['data'];
      Map? offer;
      if (data is Map) {
        offer = Map<String, dynamic>.from(data);
      }

      _openIncomingCall(from, offer);
    });
  }

  Future<void> _openIncomingCall(String from, Map? offer) async {
    if (!mounted) return;
    _openingCall = true;
    setState(() {
      callInProgress = true;
      otherUser ??= from;
      callStatusBanner = L.t('call_connecting');
    });
    HapticFeedback.mediumImpact();

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CallScreen(
          roomCode: widget.roomCode,
          username: widget.username,
          otherUser: from,
          isIncoming: true,
          initialOffer: offer,
        ),
      ),
    );

    if (!mounted) return;
    setState(() {
      callInProgress = false;
      callStatusBanner = '';
      _openingCall = false;
    });
  }

  void _listenChatPresence() {
    _presenceSub?.cancel();
    _presenceSub = DyhanieApi.instance.events.listen((m) {
      if (m['type']?.toString() != 'signal') return;
      final p = m['payload'];
      if (p is! Map) return;

      final from = (p['from']?.toString() ?? '').toLowerCase();
      final me = widget.username.toLowerCase();
      if (from.isEmpty || from == me) return;
      if ((p['kind']?.toString() ?? '') != 'chat_presence') return;

      final data = p['data'];
      final inside = data is Map && data['in'] == true;

      _lastPeerPresenceAt = DateTime.now();

      if (!mounted) return;
      setState(() => otherOnline = inside);
    });
  }

  // ---------------------------------------------------------------------------
  // Exit / settings
  // ---------------------------------------------------------------------------

  void _exitRoom() {
    _presenceTimer?.cancel();
    _presenceTimer = null;

    if (!mounted) return;
    Navigator.pop(context);
    unawaited(_cleanupAfterExit());
  }

  Future<void> _cleanupAfterExit() async {
    try {
      await DyhanieApi.instance
          .chatPresence(room: widget.roomCode, inside: false)
          .timeout(const Duration(milliseconds: 500));
    } catch (_) {}
    await _announceInChat(false);
    try {
      await DyhanieApi.instance
          .chatPresence(room: widget.roomCode, inside: false)
          .timeout(const Duration(milliseconds: 400));
    } catch (_) {}
    try {
      if (!wipeOnExit) {
        await _saveHistory();
      } else {
        await MediaMessageCache.instance.clearRoom(widget.roomCode);
        await _history.clear(widget.roomCode);
      }
    } catch (_) {}
    try {
      _p2p?.dispose();
    } catch (_) {}
  }

  void _openSettings() {
    final scheme = Theme.of(context).colorScheme;
    final onSurf = scheme.onSurface;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: scheme.surfaceContainerHigh,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setM) {
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: onSurf.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      showSearch ? Icons.close : Icons.search,
                      color: onSurf.withValues(alpha: 0.75),
                    ),
                    title: Text(
                      showSearch ? L.t('close') : L.t('search_messages'),
                      style: FontService.style(color: onSurf),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      setState(() {
                        showSearch = !showSearch;
                        if (!showSearch) {
                          searchQuery = '';
                          _searchCtrl.clear();
                        }
                      });
                    },
                  ),
                  const Divider(height: 24),
                  Text(
                    L.t('font_size'),
                    style: FontService.style(
                      color: onSurf.withValues(alpha: 0.7),
                      fontSize: 13,
                    ),
                  ),
                  Slider(
                    value: messageFontSize,
                    min: 12,
                    max: 24,
                    divisions: 12,
                    label: messageFontSize.round().toString(),
                    onChanged: (v) {
                      setM(() => messageFontSize = v);
                      setState(() => messageFontSize = v);
                    },
                    onChangeEnd: (_) => _saveChatConfig(),
                  ),
                  Text(
                    selectedTime <= 0
                        ? 'Время жизни: не исчезать'
                        : 'Время жизни: ${selectedTime ~/ 60} м ${selectedTime % 60} с',
                    style: FontService.style(
                      color: onSurf.withValues(alpha: 0.7),
                      fontSize: 13,
                    ),
                  ),
                  Slider(
                    value: selectedTime.clamp(0, 600).toDouble(),
                    min: 0,
                    max: 600,
                    divisions: 60,
                    label: selectedTime <= 0
                        ? '∞'
                        : (selectedTime < 60
                            ? '$selectedTime с'
                            : '${selectedTime ~/ 60}:${(selectedTime % 60).toString().padLeft(2, '0')}'),
                    onChanged: (v) {
                      final t = v.round();
                      setM(() => selectedTime = t);
                      setState(() => selectedTime = t);
                    },
                    onChangeEnd: (_) => _saveChatConfig(),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Размер сообщений',
                    style: FontService.style(
                      color: onSurf.withValues(alpha: 0.7),
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: List.generate(5, (i) {
                      const labels = ['XS', 'S', 'M', 'L', 'XL'];
                      final selected = messageSizeLevel == i;
                      return ChoiceChip(
                        label: Text(
                          labels[i],
                          style: FontService.style(
                            fontSize: 12,
                            color: selected ? scheme.surface : onSurf,
                          ),
                        ),
                        selected: selected,
                        selectedColor: onSurf,
                        backgroundColor: onSurf.withValues(alpha: 0.08),
                        onSelected: (_) async {
                          setM(() => messageSizeLevel = i);
                          setState(() => messageSizeLevel = i);
                          await _saveChatConfig();
                        },
                      );
                    }),
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(AppIcons.image,
                        color: onSurf.withValues(alpha: 0.75)),
                    title: Text(L.t('background'),
                        style: FontService.style(color: onSurf)),
                    onTap: () async {
                      Navigator.pop(ctx);
                      final img = await _picker.pickImage(
                        source: ImageSource.gallery,
                        maxWidth: 1920,
                      );
                      if (img != null) {
                        final b = await img.readAsBytes();
                        if (!mounted) return;
                        setState(() => backgroundBytes = b);
                      }
                    },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(AppIcons.share,
                        color: onSurf.withValues(alpha: 0.75)),
                    title: Text(L.t('share_history'),
                        style: FontService.style(color: onSurf)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _shareHistory();
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    IncomingCallService.instance.setChatHandlingRoom(widget.roomCode);
    super.initState();
    _loadChatConfig();
    _listenChatPresence();
    p2pStatusText = L.t('none');
    connectionMode = L.t('no_connection');
    WidgetsBinding.instance.addObserver(this);
    _loadAvatars();
    _updateConnectionMode();
    _clearMyIncomingSignal();
    Future.delayed(const Duration(milliseconds: 300), _loadSavedHistory);
    Future.delayed(const Duration(milliseconds: 200), _bootstrapPeer);
    _listenServerMessages();
    Future.microtask(_ensureMic);
    _listenIncomingCalls();
    UnreadChatsService.instance.startListening(openRoomCode: widget.roomCode);
    UnreadChatsService.instance.clear(widget.roomCode);
    DyhanieApi.instance
        .chatNudgeAck(room: widget.roomCode)
        .catchError((_) {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _clearMyIncomingSignal();
      Future(() async {
        await _syncServerMessages();
        // _flushPending убран
        if (!mounted) return;

        final peer =
            (otherUser ?? _otherFromRoomCode())?.toLowerCase().trim();
        if (peer != null && peer.isNotEmpty) {
          unawaited(_tickPresence(peer));
        }

        if (TransportModeService.instance.isP2p &&
            otherUser != null &&
            _p2p == null) {
          await _startP2P(otherUser!);
        }
      });
    }
  }

  @override
  void dispose() {
    _stopPresencePolling();
    _presenceSub?.cancel();
    IncomingCallService.instance.setChatHandlingRoom(null);
    WidgetsBinding.instance.removeObserver(this);
    UnreadChatsService.instance.startListening();
    UnreadChatsService.instance.clear(widget.roomCode);
    _p2pMsgSub?.cancel();
    _p2pStatusSub?.cancel();
    _apiMsgSub?.cancel();
    _p2p?.dispose();
    _callSignalSub?.cancel();
    _audioRecorder.dispose();
    for (final t in _timers.values) {
      t.cancel();
    }
    _controller.dispose();
    _searchCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = _visibleMessages;
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final onSurf = Theme.of(context).colorScheme.onSurface;

    return Scaffold(
      backgroundColor: bg,
      body: Container(
        decoration: BoxDecoration(
          color: bg,
          image: backgroundBytes != null
              ? DecorationImage(
                  image: MemoryImage(backgroundBytes!),
                  fit: BoxFit.cover,
                  colorFilter: ColorFilter.mode(
                    Colors.black.withValues(alpha: 0.55),
                    BlendMode.darken,
                  ),
                )
              : null,
        ),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: ChatAppBar(
            blockServerMessages: blockServerMessages,
            showSearch: showSearch,
            searchController: _searchCtrl,
            isDirect: _looksLikeDirectDialog(widget.roomCode),
            roomCode: widget.roomCode,
            otherUser: otherUser,
            otherOnline: otherOnline,
            connectionMode: connectionMode,
            wipeOnExit: wipeOnExit,
            myUsername: widget.username,
            myAvatarBytes: myAvatarBytes,
            otherAvatarBytes: otherAvatarBytes,
            onBack: _exitRoom,
            onToggleSearch: () => setState(() {
              showSearch = !showSearch;
              if (!showSearch) {
                searchQuery = '';
                _searchCtrl.clear();
              }
            }),
            onSearchChanged: (v) => setState(() => searchQuery = v.trim()),
            onCall: _startCall,
            onToggleWipe: () async {
              setState(() => wipeOnExit = !wipeOnExit);
              final messenger = ScaffoldMessenger.of(context);
              await _saveChatConfig();
              if (!mounted) return;
              messenger.showSnackBar(
                SnackBar(
                  content: Text(
                    wipeOnExit ? L.t('wipe_on_exit') : L.t('keep_on_exit'),
                  ),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
            onSettings: _openSettings,
          ),
          body: Stack(
            clipBehavior: Clip.none,
            children: [
              Column(
                children: [
                  if (callStatusBanner.isNotEmpty)
                    Container(
                      width: double.infinity,
                      color: callInProgress
                          ? Colors.green.withValues(alpha: 0.25)
                          : onSurf.withValues(alpha: 0.08),
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        callStatusBanner,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: onSurf),
                      ),
                    ),
                  if (pinned != null)
                    Container(
                      width: double.infinity,
                      color: onSurf.withValues(alpha: 0.08),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            AppIcons.pin,
                            color: onSurf.withValues(alpha: 0.55),
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${pinned!['username']}: ${pinned!['text']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: onSurf.withValues(alpha: 0.75),
                                fontSize: 13,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              AppIcons.close,
                              size: 16,
                              color: onSurf.withValues(alpha: 0.4),
                            ),
                            onPressed: () => setState(() => pinned = null),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: ChatMessageList(
                      messages: list,
                      myUsername: widget.username,
                      fontSize: messageFontSize,
                      videoSizeLevel: messageSizeLevel,
                      isSavedChat: isSavedChat,
                      selectedTime: selectedTime,
                      remaining: _remaining,
                      otherLastRead: otherLastRead,
                      scrollController: _scroll,
                      onLongPress: _messageActions,
                      onSwipeDelete: _deleteForBoth,
                    ),
                  ),
                  if (typingUser != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 16, bottom: 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '@$typingUser ${L.t('typing')}',
                          style: TextStyle(
                            color: onSurf.withValues(alpha: 0.4),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ChatMediaStrip(
                        onRecordStart: _onMediaRecordStart,
                        onRecordEnd: _onMediaRecordEnd,
                        onRecordCancel: _onMediaRecordCancel,
                      ),
                      ChatInputBar(
                        controller: _controller,
                        p2pConnected: p2pConnected,
                        blockServerMessages: blockServerMessages,
                        replyTo: replyTo,
                        onAttach: _attach,
                        onEmoji: _openEmoji,
                        onSend: _onSendPressed,
                        onClearReply: () => setState(() => replyTo = null),
                      ),
                    ],
                  ),
                ],
              ),
              if (_showVideoOverlay)
                VideoCaptureOverlay(
                  key: _videoOverlayKey,
                  maxSeconds: 20,
                  onReady: () {
                    _videoOverlayKey.currentState?.startRecording();
                  },
                  onFinished: (path, ms) {
                    unawaited(_onVideoFileReady(path, ms));
                  },
                  onCancel: () {
                    if (mounted) {
                      setState(() {
                        _showVideoOverlay = false;
                      });
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}