import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/call_screen.dart';
import 'dyhanie_api.dart';
import 'contact_invite_service.dart';
import '../services/incoming_call_gate.dart';

final appNavigatorKey = GlobalKey<NavigatorState>();

class IncomingCallService {
  IncomingCallService._();
  static final IncomingCallService instance = IncomingCallService._();

  StreamSubscription? _sub;
  GlobalKey<NavigatorState>? _navKey;
  String? _myUsername;
  bool _busy = false;

  String? chatHandlingRoom;

  void attach({
    required GlobalKey<NavigatorState> navKey,
    required String myUsername,
  }) {
    _navKey = navKey;
    _myUsername = myUsername.toLowerCase().trim();
    _sub?.cancel();
    _sub = DyhanieApi.instance.events.listen(_onEvent);
  }

  void detach() {
    _sub?.cancel();
    _sub = null;
    _navKey = null;
    _myUsername = null;
    chatHandlingRoom = null;
    _busy = false;
  }

  void setChatHandlingRoom(String? room) {
    final r = room?.toLowerCase().trim();
    chatHandlingRoom = (r == null || r.isEmpty) ? null : r;
  }

  Future<void> _onEvent(Map<String, dynamic> m) async {
    if (m['type']?.toString() != 'signal') return;
    final p = m['payload'];
    if (p is! Map) return;

    final kind = p['kind']?.toString() ?? '';
    if (kind != 'call_offer') return;

    final me = _myUsername;
    if (me == null || me.isEmpty) return;

    final from = (p['from']?.toString() ?? '').toLowerCase().trim();
    if (from.isEmpty || from == me) return;

     // Чёрный список — звонок не открываем
    if (await ContactInviteService().isBlocked(from)) return;

    final room = (p['room']?.toString() ?? '').toLowerCase().trim();
    if (room.isEmpty) return;

    // этот чат уже открыт — handler в ChatScreen
    if (chatHandlingRoom != null && chatHandlingRoom == room) return;
    if (_busy) return;

    final data = p['data'];
    Map? offer;
    if (data is Map) {
      offer = Map<String, dynamic>.from(data);
    }

    _openIncoming(room: room, from: from, offer: offer);
  }

  Future<void> _openIncoming({
    required String room,
    required String from,
    Map? offer,
  }) async {
    final nav = _navKey?.currentState;
    if (nav == null) {
      IncomingCallGate.instance.unlock();
      return;
    }

    _busy = true;
    try {
      HapticFeedback.mediumImpact();
      await nav.push(
        MaterialPageRoute(
          builder: (_) => CallScreen(
            roomCode: room,
            username: _myUsername!,
            otherUser: from,
            isIncoming: true,
            initialOffer: offer,
          ),
        ),
      );
    } finally {
      _busy = false;
      IncomingCallGate.instance.unlock();
    }
  }
}