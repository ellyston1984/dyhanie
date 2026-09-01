import 'dart:async';

import 'package:flutter/foundation.dart';

import 'avatar_cache.dart';
import 'contact_invite_service.dart';
import 'dyhanie_api.dart';

/// Одна строка результата глобального поиска.
class UserSearchHit {
  final String username;
  final bool hasAvatar;
  final Uint8List? avatarBytes;
  final bool isContact;
  final bool isBlocked;
  final bool isSelf;

  const UserSearchHit({
    required this.username,
    this.hasAvatar = false,
    this.avatarBytes,
    this.isContact = false,
    this.isBlocked = false,
    this.isSelf = false,
  });

  UserSearchHit copyWith({
    Uint8List? avatarBytes,
    bool? isContact,
    bool? isBlocked,
  }) {
    return UserSearchHit(
      username: username,
      hasAvatar: hasAvatar,
      avatarBytes: avatarBytes ?? this.avatarBytes,
      isContact: isContact ?? this.isContact,
      isBlocked: isBlocked ?? this.isBlocked,
      isSelf: isSelf,
    );
  }
}

/// Глобальный поиск пользователей (отдельный сервис).
class UserSearchService {
  UserSearchService({required this.myUsername});

  final String myUsername;
  final _invites = ContactInviteService();

  final results = ValueNotifier<List<UserSearchHit>>([]);
  final isLoading = ValueNotifier<bool>(false);
  final errorText = ValueNotifier<String?>(null);

  Timer? _debounce;
  int _requestId = 0;
  String _lastQuery = '';

  static const int minQueryLength = 2;
  static const Duration debounceDuration = Duration(milliseconds: 400);
  static const int limit = 20;

  /// Вызывать из onChanged TextField.
  void onQueryChanged(String raw) {
    final q = raw.toLowerCase().trim();
    _debounce?.cancel();

    if (q.length < minQueryLength) {
      _lastQuery = '';
      results.value = [];
      isLoading.value = false;
      errorText.value = null;
      return;
    }

    if (q == _lastQuery) return;

    isLoading.value = true;
    errorText.value = null;

    _debounce = Timer(debounceDuration, () {
      _runSearch(q);
    });
  }

  /// Принудительный поиск (кнопка / onSubmitted).
  Future<void> searchNow(String raw) async {
    _debounce?.cancel();
    final q = raw.toLowerCase().trim();
    if (q.length < minQueryLength) {
      results.value = [];
      isLoading.value = false;
      return;
    }
    await _runSearch(q);
  }

  Future<void> _runSearch(String q) async {
    final id = ++_requestId;
    _lastQuery = q;
    isLoading.value = true;
    errorText.value = null;

    try {
      if (!DyhanieApi.instance.isConnected) {
        await DyhanieApi.instance.connect();
        await DyhanieApi.instance.sessionBind(myUsername);
      } else if (DyhanieApi.instance.boundUsername == null) {
        await DyhanieApi.instance.sessionBind(myUsername);
      }

      List<Map<String, dynamic>> rawUsers;
      try {
        rawUsers = await DyhanieApi.instance.usernameSearch(q, limit: limit);
      } catch (e) {
        // Fallback, если сервер без username.search
        final msg = e.toString();
        if (msg.contains('SEARCH_UNSUPPORTED') ||
            msg.contains('UNKNOWN') ||
            msg.contains('NOT_IMPLEMENTED') ||
            msg.contains('INVALID') ||
            msg.contains('timeout')) {
          rawUsers = await _fallbackExact(q);
        } else {
          rethrow;
        }
      }

      if (id != _requestId) return;

      final contacts = await _invites.getLocalContacts();
      final blocked = await _invites.getBlocked();
      final me = myUsername.toLowerCase().trim();

      final hits = <UserSearchHit>[];
      for (final m in rawUsers) {
        final u = (m['username']?.toString() ?? '').toLowerCase().trim();
        if (u.isEmpty) continue;

        hits.add(UserSearchHit(
          username: u,
          hasAvatar: m['has_avatar'] == true,
          isSelf: u == me,
          isContact: contacts.contains(u),
          isBlocked: blocked.contains(u),
        ));
      }

      hits.sort((a, b) {
        if (a.isSelf != b.isSelf) return a.isSelf ? 1 : -1;
        return a.username.compareTo(b.username);
      });

      results.value = hits;
      isLoading.value = false;

      _loadAvatars(hits, id);
    } catch (e) {
      if (id != _requestId) return;
      isLoading.value = false;
      errorText.value = e.toString();
      results.value = [];
    }
  }

  Future<List<Map<String, dynamic>>> _fallbackExact(String q) async {
    final exists = await DyhanieApi.instance.usernameExists(q);
    if (!exists) return [];
    return [
      {'username': q, 'has_avatar': true},
    ];
  }

  Future<void> _loadAvatars(List<UserSearchHit> hits, int id) async {
    for (final h in hits) {
      if (id != _requestId) return;
      if (h.isSelf) continue;
      final bytes = await AvatarCache.fetch(h.username);
      if (id != _requestId) return;
      if (bytes == null) continue;

      final updated = List<UserSearchHit>.from(results.value);
      final idx = updated.indexWhere((e) => e.username == h.username);
      if (idx < 0) continue;
      updated[idx] = updated[idx].copyWith(avatarBytes: bytes);
      results.value = updated;
    }
  }

  void clear() {
    _debounce?.cancel();
    _requestId++;
    _lastQuery = '';
    results.value = [];
    isLoading.value = false;
    errorText.value = null;
  }

  void dispose() {
    _debounce?.cancel();
    results.dispose();
    isLoading.dispose();
    errorText.dispose();
  }
}