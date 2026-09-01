import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/chat_history_service.dart';
import '../services/dialog_signal_service.dart';
import '../services/font_service.dart';
import '../services/icon_style_service.dart';
import '../services/locale_service.dart';
import '../services/unread_chats_service.dart';
import '../services/dyhanie_api.dart';
import '../services/avatar_cache.dart';
import 'chat_screen.dart';


class ChatsScreen extends StatefulWidget {
  final String myUsername;

  const ChatsScreen({super.key, required this.myUsername});

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  static const _maxPinned = 22;
  static const _prefsPinned = 'chats_pinned';
  static const _prefsNotes = 'chats_notes';

  final _signals = DialogSignalService();
  final _history = ChatHistoryService();

  final Map<String, _ChatItem> items = {};
  List<String> pinnedIds = [];
  Map<String, String> notes = {};

  StreamSubscription? _sub;
  StreamSubscription? _unreadSub;

  @override
  void initState() {
    super.initState();
    _bootstrap();

    _sub = _signals.listenMySignals(
      myUsername: widget.myUsername,
      onSignals: (map) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _applySignals(map);
        });
      },
    );

    _unreadSub = UnreadChatsService.instance.changes.listen((map) {
      if (!mounted) return;
      setState(() {
        for (final e in map.entries) {
          final prev = items[e.key];
          final other = prev?.otherUser ??
              _otherFromDialogId(e.key, widget.myUsername) ??
              e.key;
          final count = e.value;
          items[e.key] = _ChatItem(
            dialogId: e.key,
            otherUser: other,
            incomingCount: count,
            comeOnline: prev?.comeOnline ?? false,
            updatedAt: prev?.updatedAt ??
                DateTime.now().millisecondsSinceEpoch,
            hasOutbox: prev?.hasOutbox ?? false,
            isSaved: prev?.isSaved ?? false,
            preview: prev?.preview ?? '',
            avatarBytes: prev?.avatarBytes,
          );
        }
        for (final id in items.keys.toList()) {
          if (!map.containsKey(id) || (map[id] ?? 0) <= 0) {
            final prev = items[id]!;
            if (prev.incomingCount == 0 && !prev.comeOnline) continue;
            items[id] = _ChatItem(
              dialogId: prev.dialogId,
              otherUser: prev.otherUser,
              incomingCount: 0,
              comeOnline: false,
              updatedAt: prev.updatedAt,
              hasOutbox: prev.hasOutbox,
              isSaved: prev.isSaved,
              preview: prev.preview,
              avatarBytes: prev.avatarBytes,
            );
          }
        }
      });
    });
  }

  void _applySignals(Map<String, Map<String, dynamic>> map) {
    setState(() {
      final keep = <String>{};

      map.forEach((dialogId, data) {
        final type = data['type']?.toString() ?? '';
        final from = data['from']?.toString() ?? '';
        final count = data['count'] is int
            ? data['count'] as int
            : int.tryParse('${data['count']}') ?? 1;
        final ts = data['ts'] is int
            ? data['ts'] as int
            : int.tryParse('${data['ts']}') ?? 0;

        final other = _otherFromDialogId(dialogId, widget.myUsername) ?? from;
        if (other.isEmpty) return;

        keep.add(dialogId);
        final prev = items[dialogId];
        items[dialogId] = _ChatItem(
          dialogId: dialogId,
          otherUser: other,
          incomingCount: type == 'pending_in'
              ? count
              : (type == 'come_online' ? 1 : (prev?.incomingCount ?? 0)),
          comeOnline: type == 'come_online',
          updatedAt: ts > 0 ? ts : (prev?.updatedAt ?? 0),
          hasOutbox: prev?.hasOutbox ?? false,
          isSaved: prev?.isSaved ?? false,
          preview: prev?.preview ?? '',
          avatarBytes: prev?.avatarBytes,
        );
      });

      items.removeWhere(
        (id, item) =>
            !keep.contains(id) &&
            !item.hasOutbox &&
            !item.isSaved &&
            !pinnedIds.contains(id),
      );

      for (final id in items.keys.toList()) {
        if (map.containsKey(id)) continue;
        final prev = items[id]!;
        if (prev.incomingCount == 0 && !prev.comeOnline) continue;
        items[id] = _ChatItem(
          dialogId: prev.dialogId,
          otherUser: prev.otherUser,
          incomingCount: 0,
          comeOnline: false,
          updatedAt: prev.updatedAt,
          hasOutbox: prev.hasOutbox,
          isSaved: prev.isSaved,
          preview: prev.preview,
          avatarBytes: prev.avatarBytes,
        );
      }
    });
  }

    Future<void> _bootstrap() async {
    await UnreadChatsService.instance.load();
    await _loadMeta();
    await _loadSaved();
    for (final e in items.entries) {
      if (e.value.otherUser.isNotEmpty) {
        _ensureAvatar(e.value.otherUser, e.key);
      }
    }
  }

  Future<void> _loadMeta() async {
    final prefs = await SharedPreferences.getInstance();
    final pinRaw = prefs.getStringList(_prefsPinned) ?? [];
    final notesRaw = prefs.getString(_prefsNotes);
    if (!mounted) return;
    setState(() {
      pinnedIds = pinRaw.take(_maxPinned).toList();
      if (notesRaw != null && notesRaw.isNotEmpty) {
        try {
          notes = Map<String, String>.from(jsonDecode(notesRaw));
        } catch (_) {}
      }
    });
  }

  Future<void> _savePinned() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsPinned, pinnedIds);
  }

  Future<void> _saveNotes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsNotes, jsonEncode(notes));
  }

  Future<void> _loadSaved() async {
    final saved = await _history.listSaved();
    final unreadMap = UnreadChatsService.instance.snapshot;
    if (!mounted) return;
    setState(() {
      for (final row in saved) {
        final id = row['roomCode']?.toString() ?? '';
        if (id.isEmpty) continue;
        final other = _otherFromDialogId(id, widget.myUsername) ?? id;
        final prev = items[id];
        items[id] = _ChatItem(
          dialogId: id,
          otherUser: other,
          incomingCount: unreadMap[id] ?? prev?.incomingCount ?? 0,
          comeOnline: prev?.comeOnline ?? false,
          updatedAt:
              (row['updatedAt'] as int?) ?? (prev?.updatedAt ?? 0),
          hasOutbox: prev?.hasOutbox ?? false,
          isSaved: true,
          preview: row['preview']?.toString() ?? prev?.preview ?? '',
          avatarBytes: prev?.avatarBytes,
        );
      }
    });
    for (final e in items.entries) {
      if (e.value.otherUser.isNotEmpty) {
        _ensureAvatar(e.value.otherUser, e.key);
      }
    }

  }

  String? _otherFromDialogId(String dialogId, String me) {
    final parts = dialogId.split('_');
    if (parts.length == 2) {
      return parts[0] == me ? parts[1] : parts[0];
    }
    if (dialogId.startsWith('${me}_')) {
      return dialogId.substring(me.length + 1);
    }
    if (dialogId.endsWith('_$me')) {
      return dialogId.substring(0, dialogId.length - me.length - 1);
    }
    return null;
  }

  List<_ChatItem> get _sorted {
    final list = items.values.toList();
    list.sort((a, b) {
      final ap = pinnedIds.contains(a.dialogId);
      final bp = pinnedIds.contains(b.dialogId);
      if (ap && !bp) return -1;
      if (!ap && bp) return 1;
      if (ap && bp) {
        return pinnedIds
            .indexOf(a.dialogId)
            .compareTo(pinnedIds.indexOf(b.dialogId));
      }
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return list;
  }

  void _open(_ChatItem item) {
    UnreadChatsService.instance.clear(item.dialogId);
    DyhanieApi.instance.chatNudgeAck(room: item.dialogId).catchError((_) {});

    setState(() {
      final prev = items[item.dialogId];
      if (prev != null) {
        items[item.dialogId] = _ChatItem(
          dialogId: prev.dialogId,
          otherUser: prev.otherUser,
          incomingCount: 0,
          comeOnline: false,
          updatedAt: prev.updatedAt,
          hasOutbox: prev.hasOutbox,
          isSaved: prev.isSaved,
          preview: prev.preview,
          avatarBytes: prev.avatarBytes,
        );
      }
    });

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          roomCode: item.dialogId,
          username: widget.myUsername,
        ),
      ),
    ).then((_) async {
      await UnreadChatsService.instance.clear(item.dialogId);
      if (!mounted) return;
      setState(() {
        final prev = items[item.dialogId];
        if (prev != null) {
          items[item.dialogId] = _ChatItem(
            dialogId: prev.dialogId,
            otherUser: prev.otherUser,
            incomingCount: 0,
            comeOnline: false,
            updatedAt: prev.updatedAt,
            hasOutbox: prev.hasOutbox,
            isSaved: prev.isSaved,
            preview: prev.preview,
            avatarBytes: prev.avatarBytes,
          );
        }
      });
      await _loadSaved();
    });
  }
  
  Future<void> _sendNudge(_ChatItem item) async {
    try {
      await DyhanieApi.instance.chatNudge(
        to: item.otherUser,
        room: item.dialogId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L.t('signal_sent'))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${L.t('error')}: $e')),
      );
    }
  }

  Future<void> _togglePin(_ChatItem item) async {
    final id = item.dialogId;
    setState(() {
      if (pinnedIds.contains(id)) {
        pinnedIds.remove(id);
      } else {
        if (pinnedIds.length >= _maxPinned) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                L.tParams('pin_limit', {'n': '$_maxPinned'}),
              ),
            ),
          );
          return;
        }
        pinnedIds.insert(0, id);
      }
    });
    await _savePinned();
  }

  void _editNote(_ChatItem item) {
    final scheme = Theme.of(context).colorScheme;
    final onSurf = scheme.onSurface;
    final ctrl = TextEditingController(text: notes[item.dialogId] ?? '');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: scheme.surfaceContainerHigh,
        title: Text(
          L.tParams('note_for', {'name': item.otherUser}),
          style: FontService.style(color: onSurf),
        ),
        content: TextField(
          controller: ctrl,
          style: FontService.style(color: onSurf),
          decoration: InputDecoration(
            hintText: L.t('note'),
            hintStyle: TextStyle(color: onSurf.withValues(alpha: 0.3)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              L.t('cancel'),
              style: FontService.style(
                color: onSurf.withValues(alpha: 0.55),
              ),
            ),
          ),
          TextButton(
            onPressed: () async {
              final t = ctrl.text.trim();
              if (t.isEmpty) {
                notes.remove(item.dialogId);
              } else {
                notes[item.dialogId] = t;
              }
              await _saveNotes();
              if (mounted) setState(() {});
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: Text(
              L.t('save'),
              style: FontService.style(color: onSurf),
            ),
          ),
        ],
      ),
    );
  }

    Future<void> _ensureAvatar(String other, String dialogId) async {
    if (other.isEmpty) return;

    final bytes = await AvatarCache.fetch(
      other,
      forceNetwork: true,
      bindUsername: widget.myUsername,
    );

    if (!mounted || bytes == null) return;

    final prev = items[dialogId];
    if (prev == null) return;

    setState(() {
      items[dialogId] = _ChatItem(
        dialogId: prev.dialogId,
        otherUser: prev.otherUser,
        incomingCount: prev.incomingCount,
        comeOnline: prev.comeOnline,
        updatedAt: prev.updatedAt,
        hasOutbox: prev.hasOutbox,
        isSaved: prev.isSaved,
        preview: prev.preview,
        avatarBytes: bytes, // записать bytes с сервера
      );
    });
  }
  

  Future<void> _deleteChat(_ChatItem item) async {
    final scheme = Theme.of(context).colorScheme;
    final onSurf = scheme.onSurface;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: scheme.surfaceContainerHigh,
        title: Text(
          L.t('delete_chat_title'),
          style: FontService.style(color: onSurf),
        ),
        content: Text(
          L.tParams('delete_chat_body', {'name': item.otherUser}),
          style: FontService.style(
            color: onSurf.withValues(alpha: 0.75),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              L.t('cancel'),
              style: FontService.style(
                color: onSurf.withValues(alpha: 0.55),
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              L.t('delete_chat'),
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await _history.clear(item.dialogId);
    await UnreadChatsService.instance.clear(item.dialogId);
    pinnedIds.remove(item.dialogId);
    notes.remove(item.dialogId);
    await _savePinned();
    await _saveNotes();
    if (!mounted) return;
    setState(() => items.remove(item.dialogId));
  }

  void _chatActions(_ChatItem item) {
    final scheme = Theme.of(context).colorScheme;
    final onSurf = scheme.onSurface;
    final isPinned = pinnedIds.contains(item.dialogId);

    showModalBottomSheet(
      context: context,
      backgroundColor: scheme.surfaceContainerHigh,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                AppIcons.pin,
                color: isPinned
                    ? Colors.amberAccent
                    : onSurf.withValues(alpha: 0.75),
              ),
              title: Text(
                isPinned ? L.t('unpin_chat') : L.t('pin_chat'),
                style: FontService.style(color: onSurf),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _togglePin(item);
              },
            ),
            ListTile(
              leading: Icon(
                AppIcons.note,
                color: onSurf.withValues(alpha: 0.75),
              ),
              title: Text(
                L.t('note'),
                style: FontService.style(color: onSurf),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _editNote(item);
              },
            ),
            ListTile(
              leading: Icon(
                AppIcons.delete,
                color: Colors.redAccent,
              ),
              title: Text(
                L.t('delete'),
                style: FontService.style(color: Colors.redAccent),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _deleteChat(item);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _unreadSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = _sorted;
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final onSurf = Theme.of(context).colorScheme.onSurface;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        title: Text(
          L.t('chats'),
          style: FontService.style(fontSize: 18, color: onSurf),
        ),
        iconTheme: IconThemeData(color: onSurf),
      ),
      body: list.isEmpty
          ? Center(
              child: Text(
                L.t('chats_empty'),
                textAlign: TextAlign.center,
                style: FontService.style(
                  color: onSurf.withValues(alpha: 0.4),
                ),
              ),
            )
          : ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, __) => Divider(
                color: onSurf.withValues(alpha: 0.06),
                height: 1,
              ),
              itemBuilder: (context, i) {
                final item = list[i];
                final isPinned = pinnedIds.contains(item.dialogId);
                final note = notes[item.dialogId];

                return ListTile(
                  tileColor: item.incomingCount > 0
                      ? Colors.blueAccent.withValues(alpha: 0.12)
                      : null,
                  leading: CircleAvatar(
                    backgroundColor: onSurf.withValues(alpha: 0.1),
                    backgroundImage: item.avatarBytes != null
                        ? MemoryImage(item.avatarBytes!)
                        : null,
                    child: item.avatarBytes == null
                        ? Text(
                            item.otherUser.isNotEmpty
                                ? item.otherUser[0].toUpperCase()
                                : '?',
                            style: FontService.style(color: onSurf),
                          )
                        : null,
                  ),
                  title: Row(
                    children: [
                      if (isPinned) ...[
                        Icon(AppIcons.pin,
                            size: 14, color: Colors.amberAccent),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          '@${item.otherUser}',
                          style: FontService.style(color: onSurf),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                 subtitle: (note != null && note.isNotEmpty)
                      ? Text(
                          note,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: FontService.style(
                            color: onSurf.withValues(alpha: 0.55),
                            fontSize: 12,
                          ),
                        )
                      : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (item.badge > 0)
                        Container(
                          margin: const EdgeInsets.only(right: 4),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: item.comeOnline
                                ? Colors.orangeAccent
                                : Colors.blueAccent,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${item.badge}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      IconButton(
                        tooltip: L.t('signal'),
                        icon: Icon(
                          AppIcons.signal,
                          color: onSurf.withValues(alpha: 0.6),
                          size: 20,
                        ),
                        onPressed: () => _sendNudge(item),
                      ),
                      if (item.hasOutbox && item.badge == 0)
                        Icon(AppIcons.schedule,
                            color: onSurf.withValues(alpha: 0.4), size: 18)
                      else if (item.isSaved && item.badge == 0)
                        Icon(AppIcons.bookmark,
                            color: onSurf.withValues(alpha: 0.35), size: 18),
                      IconButton(
                        icon: Icon(
                          AppIcons.more,
                          color: onSurf.withValues(alpha: 0.55),
                        ),
                        onPressed: () => _chatActions(item),
                      ),
                    ],
                  ),
                  onTap: () => _open(item),
                  onLongPress: () => _chatActions(item),
                );
              },
            ),
    );
  }
}

class _ChatItem {
  final String dialogId;
  final String otherUser;
  final int incomingCount;
  final bool comeOnline;
  final int updatedAt;
  final bool hasOutbox;
  final bool isSaved;
  final String preview;
  final Uint8List? avatarBytes;

  _ChatItem({
    required this.dialogId,
    required this.otherUser,
    required this.incomingCount,
    required this.comeOnline,
    required this.updatedAt,
    required this.hasOutbox,
    this.isSaved = false,
    this.preview = '',
    this.avatarBytes,
  });

  int get badge => comeOnline ? 1 : incomingCount;

  String get subtitle {
    if (comeOnline) return L.t('waiting_in_chat');
    if (incomingCount > 0) {
      return L.tParams('incoming_count', {'n': '$incomingCount'});
    }
    if (hasOutbox) return L.t('outbox_waiting');
    if (preview.isNotEmpty) return preview;
    return L.t('dialog');
  }
}