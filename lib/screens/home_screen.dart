import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/dyhanie_api.dart';
import '../services/contact_invite_service.dart';
import '../services/dialog_signal_service.dart';
import '../services/font_service.dart';
import '../services/icon_style_controller.dart';
import '../services/locale_service.dart';
import '../services/incoming_call_service.dart';
import '../services/unread_chats_service.dart';
import '../services/transport_mode_service.dart';
import '../services/push/app_badge_aggregator.dart';
import '../services/push/push_token_service.dart';
import '../services/push/push_message_handler.dart';
import '../services/system_incoming_call/system_incoming_call.dart';
import '../services/push/incoming_call_launch.dart';

import 'auto_lock_settings_screen.dart';
import 'chats_screen.dart';
import 'chat_screen.dart';
import 'contacts_screen.dart';
import 'join_room_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';
import 'vpn_screen.dart';
import 'welcome_screen.dart';
import 'call_screen.dart';
import 'recovery_phrase_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String username = '';
  Uint8List? avatarBytes;
  int contactsBadge = 0;
  int chatsBadge = 0;
  int _inviteCount = 0;
  int _msgSignalCount = 0;

  final _invites = ContactInviteService();
  final _signals = DialogSignalService();
  StreamSubscription? _inviteSub;
  StreamSubscription? _msgSignalSub;
  StreamSubscription? _unreadSub;
  StreamSubscription? _pushEventsSub;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  String _newRoomCode() {
    final r = Random();
    return List.generate(6, (_) => r.nextInt(10)).join();
  }

  void _createRoom() {
    if (username.isEmpty) return;
    final code = _newRoomCode();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          roomCode: code,
          username: username,
        ),
      ),
    );
  }

  void listenPushEvents() {
    const events = EventChannel('su.dyhanie/push_events');
    events.receiveBroadcastStream().listen((e) {
      if (e is Map) {
        PushMessageHandler.instance.handle(Map<String, dynamic>.from(e));
      }
    });
  }

  void _joinRoom() {
    if (username.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => JoinRoomScreen(username: username),
      ),
    );
  }

    Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString('username') ?? '';
    final b64 = prefs.getString('avatar');
    Uint8List? bytes;

    await UnreadChatsService.instance.load();
    UnreadChatsService.instance.startListening();
    _unreadSub?.cancel();
    _unreadSub = UnreadChatsService.instance.changes.listen((_) {
      if (!mounted) return;
      setState(() {
        chatsBadge = UnreadChatsService.instance.dialogCount;
      });
    });
    if (mounted) {
      setState(() {
        chatsBadge = UnreadChatsService.instance.dialogCount;
      });
    }

    if (b64 != null && b64.isNotEmpty) {
      try {
        bytes = base64Decode(b64);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      username = name;
      avatarBytes = bytes;
    });

    _startBadgeListeners(name);

    if (name.isNotEmpty) {
      IncomingCallService.instance.attach(
        navKey: appNavigatorKey,
        myUsername: name,
      );
      SystemIncomingCall.instance.attach(
        navKey: appNavigatorKey,
        myUsername: name,
      );
      AppBadgeAggregator.instance.start();
      unawaited(PushTokenService.instance.registerWithServer());

      _pushEventsSub?.cancel();
      _pushEventsSub = const EventChannel('su.dyhanie/push_events')
          .receiveBroadcastStream()
          .listen((e) {
        if (e is Map) {
          unawaited(
            PushMessageHandler.instance.handle(
              Map<String, dynamic>.from(e),
            ),
          );
        }
      });

      unawaited(_handleIncomingCallLaunch(name));

      final shown = prefs.getBool('recovery_phrase_shown') ?? false;
      if (!shown) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const RecoveryPhraseScreen(
                popOnDone: true,
                forceComplete: true,
              ),
            ),
          );
        });
      }
    }
  }

  Future<void> _handleIncomingCallLaunch(String myName) async {
    final raw = await IncomingCallLaunch.instance.take();
    if (raw == null || !mounted) return;

    final from = (raw['from'] ?? '').toString();
    final room = (raw['room'] ?? '').toString();
    if (from.isEmpty || room.isEmpty) return;

    final api = DyhanieApi.instance;
    try {
      if (!api.isConnected) await api.connect();
    } catch (_) {}

    if (IncomingCallLaunch.instance.isDecline(raw)) {
      try {
        await api.request('signal', payload: {
          'room': room,
          'to': from,
          'kind': 'call_decline',
        });
      } catch (_) {}
      try {
        await api.request('call.pending_clear', payload: {});
      } catch (_) {}
      return;
    }

    if (!IncomingCallLaunch.instance.isAccept(raw)) return;

    Map<String, dynamic>? offer;
    try {
      final res = await api.request('call.pending_offer', payload: {});
      final payload = res['payload'] ?? res;
      if (payload is Map && payload['offer'] is Map) {
        final o = Map<String, dynamic>.from(payload['offer'] as Map);
        offer = o['data'] is Map
            ? Map<String, dynamic>.from(o['data'] as Map)
            : o;
      }
    } catch (_) {}

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CallScreen(
          roomCode: room,
          username: myName,
          otherUser: from,
          isIncoming: true,
          initialOffer: offer,
        ),
      ),
    );
    try {
      await api.request('call.pending_clear', payload: {});
    } catch (_) {}
  }

  void _recalcBadge() {
    if (!mounted) return;
    setState(() => contactsBadge = _inviteCount + _msgSignalCount);
    AppBadgeAggregator.instance.setContactsBadge(contactsBadge);
  }

  Future<void> _refreshInviteBadge() async {
    if (username.isEmpty) {
      _inviteCount = 0;
      _recalcBadge();
      return;
    }
    try {
      final list = await _invites.fetchInvites();
      final incoming = list['incoming'] as List? ?? [];
      _inviteCount = incoming.length;
    } catch (_) {
      _inviteCount = 0;
    }
    _recalcBadge();
  }

  void _startBadgeListeners(String name) {
    _inviteSub?.cancel();
    _msgSignalSub?.cancel();

    if (name.isEmpty) {
      _inviteCount = 0;
      _msgSignalCount = 0;
      _recalcBadge();
      return;
    }

    _inviteSub = _invites.listenInvites(
      myUsername: name,
      onData: (list) {
        _inviteCount = list.length;
        _recalcBadge();
      },
    );

    _msgSignalSub = _signals.listenMySignals(
      myUsername: name,
      onSignals: (map) {
        int count = 0;
        map.forEach((_, data) {
          final t = data['type']?.toString() ?? '';
          if (t == 'pending_in' || t == 'come_online') count++;
        });
        _msgSignalCount = count;
        _recalcBadge();
      },
    );

    _refreshInviteBadge();
  }

  @override
  void dispose() {
    _inviteSub?.cancel();
    _msgSignalSub?.cancel();
    _unreadSub?.cancel();
    _pushEventsSub?.cancel();
    AppBadgeAggregator.instance.stop();
    IncomingCallService.instance.detach();
    SystemIncomingCall.instance.detach();
    super.dispose();
  }

  void _logout() {
    unawaited(AppBadgeAggregator.instance.clearAll());
    AppBadgeAggregator.instance.stop();
    IncomingCallService.instance.detach();
    SystemIncomingCall.instance.detach();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => const WelcomeScreen(goHomeOnContinue: true),
      ),
      (_) => false,
    );
  }

  Future<void> _clearCache() async {
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: scheme.surfaceContainerHigh,
        title: Text(L.t('clear_cache_title')),
        content: Text(L.t('clear_cache_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              L.t('clear'),
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('chat_history_'));
    for (final k in keys) {
      await prefs.remove(k);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L.t('cache_cleared'))),
    );
  }

  Future<void> _openProfile() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ProfileScreen(username: username),
      ),
    );
    await _loadProfile();
    if (mounted) setState(() {});
  }

  Future<void> _openContacts() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ContactsScreen(myUsername: username),
      ),
    );
    await _refreshInviteBadge();
  }

  Future<void> _openChats() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatsScreen(myUsername: username),
      ),
    );
    if (mounted) {
      setState(() {
        chatsBadge = UnreadChatsService.instance.dialogCount;
      });
    }
  }

  /// Текстовая ссылка в углах app bar
  Widget _cornerLink({
    required String label,
    required VoidCallback onTap,
    TextAlign align = TextAlign.left,
    double opacity = 0.7,
  }) {
    final onSurf = Theme.of(context).colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
        child: Text(
          label,
          textAlign: align,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: FontService.style(
            fontSize: 12,
            fontWeight: FontWeight.w400,
            letterSpacing: 0.2,
            color: onSurf.withValues(alpha: opacity),
          ),
        ),
      ),
    );
  }

  /// Пункт под «Дыхание» + опциональный badge
  Widget _mainLink({
    required String label,
    required VoidCallback onTap,
    int badge = 0,
  }) {
    final onSurf = Theme.of(context).colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: FontService.style(
                fontSize: 16,
                fontWeight: FontWeight.w400,
                letterSpacing: 0.6,
                color: onSurf.withValues(alpha: 0.85),
              ),
            ),
            if (badge > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.redAccent,
                  borderRadius: BorderRadius.circular(10),
                ),
                constraints: const BoxConstraints(minWidth: 18),
                child: Text(
                  badge > 99 ? '99+' : '$badge',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final onSurf = Theme.of(context).colorScheme.onSurface;
    final bg = Theme.of(context).scaffoldBackgroundColor;

    return AnimatedBuilder(
      animation: Listenable.merge([
        IconStyleController.instance,
        TransportModeService.instance,
        // чтобы подписи обновлялись при смене языка
        // если LocaleController — ChangeNotifier:
        // LocaleController.instance,
      ]),
      builder: (context, _) {
        return Scaffold(
          backgroundColor: bg,
          body: SafeArea(
            child: Column(
              children: [
                // —— Верх: слева настройки/выход, справа vpn/кэш/автолок ——
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _cornerLink(
                              label: L.t('settings'),
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const SettingsScreen(),
                                  ),
                                );
                              },
                            ),
                            _cornerLink(
                              label: L.t('logout'),
                              onTap: _logout,
                              opacity: 0.5,
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            _cornerLink(
                              label: L.t('vpn'),
                              align: TextAlign.right,
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const VpnScreen(),
                                  ),
                                );
                              },
                            ),
                            _cornerLink(
                              label: L.t('clear_cache'),
                              align: TextAlign.right,
                              onTap: _clearCache,
                            ),
                            _cornerLink(
                              label: L.t('auto_lock'),
                              align: TextAlign.right,
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        const AutoLockSettingsScreen(),
                                  ),
                                );
                              },
                            ),
                            // ★ переключатель транспорта
                            _cornerLink(
                              label: TransportModeService.instance.label,
                              align: TextAlign.right,
                              opacity: 0.95, // чуть ярче — «светится»
                              onTap: () async {
                                await TransportModeService.instance.toggle();
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // —— Центр: аватар + имя + Дыхание + 4 пункта ——
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GestureDetector(
                            onTap: _openProfile,
                            child: Column(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(24),
                                  child: SizedBox(
                                    width: 168,
                                    height: 252,
                                    child: avatarBytes != null &&
                                            avatarBytes!.isNotEmpty
                                        ? Image.memory(
                                            avatarBytes!,
                                            fit: BoxFit.cover,
                                            width: 168,
                                            height: 252,
                                            gaplessPlayback: true,
                                            errorBuilder: (_, __, ___) =>
                                                Container(
                                              color: onSurf.withValues(
                                                  alpha: 0.08),
                                              alignment: Alignment.center,
                                              child: Icon(
                                                Icons.broken_image,
                                                color: onSurf.withValues(
                                                    alpha: 0.35),
                                              ),
                                            ),
                                          )
                                        : Container(
                                            color: onSurf.withValues(
                                                alpha: 0.08),
                                            alignment: Alignment.center,
                                            child: Text(
                                              username.isNotEmpty
                                                  ? username[0].toUpperCase()
                                                  : '?',
                                              style: FontService.style(
                                                fontSize: 56,
                                                color: onSurf,
                                              ),
                                            ),
                                          ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  '@$username',
                                  style: FontService.style(
                                    fontSize: 17,
                                    color: onSurf.withValues(alpha: 0.75),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  L.t('profile'),
                                  style: FontService.style(
                                    fontSize: 11,
                                    color: onSurf.withValues(alpha: 0.35),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),
                          Text(
                            L.t('app_name'),
                            style: FontService.style(
                              fontSize: 32,
                              fontWeight: FontWeight.w300,
                              letterSpacing: 3,
                              color: onSurf,
                            ),
                          ),
                          const SizedBox(height: 20),

                          // 4 строки под названием
                          _mainLink(
                            label: L.t('create_room'),
                            onTap: _createRoom,
                          ),
                          _mainLink(
                            label: L.t('join_by_code'),
                            onTap: _joinRoom,
                          ),
                          _mainLink(
                            label: L.t('saved_chats'),
                            badge: chatsBadge,
                            onTap: _openChats,
                          ),
                          _mainLink(
                            label: L.t('contacts'),
                            badge: contactsBadge,
                            onTap: _openContacts,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}