import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/avatar_cache.dart';
import '../services/contact_invite_service.dart';
import '../services/font_service.dart';
import '../services/locale_service.dart';

class BlacklistScreen extends StatefulWidget {
  final String myUsername;

  const BlacklistScreen({super.key, required this.myUsername});

  @override
  State<BlacklistScreen> createState() => _BlacklistScreenState();
}

class _BlacklistScreenState extends State<BlacklistScreen> {
  final _invites = ContactInviteService();
  List<String> blocked = [];
  final Map<String, Uint8List?> avatars = {};
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    final list = await _invites.getBlocked();
    if (!mounted) return;
    setState(() {
      blocked = list;
      loading = false;
    });
    for (final name in list) {
      final bytes = await AvatarCache.fetch(name);
      if (!mounted) return;
      setState(() => avatars[name] = bytes);
    }
  }

  Future<void> _unblock(String name) async {
    final scheme = Theme.of(context).colorScheme;
    final onSurf = scheme.onSurface;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: scheme.surfaceContainerHigh,
        title: Text(
          L.tParams('unblock_confirm', {'name': name}),
          style: FontService.style(color: onSurf),
        ),
        content: Text(
          L.t('unblock_confirm_body'),
          style: FontService.style(color: onSurf.withValues(alpha: 0.75)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              L.t('cancel'),
              style: FontService.style(color: onSurf.withValues(alpha: 0.55)),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              L.t('unblock'),
              style: FontService.style(color: Colors.greenAccent),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await _invites.unblockUser(name);
    if (!mounted) return;
    setState(() {
      blocked.remove(name);
      avatars.remove(name);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(L.tParams('unblocked_user', {'name': name})),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final onSurf = Theme.of(context).colorScheme.onSurface;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        title: Text(
          L.t('blacklist'),
          style: FontService.style(fontSize: 18, color: onSurf),
        ),
        iconTheme: IconThemeData(color: onSurf),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : blocked.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      L.t('blacklist_empty'),
                      textAlign: TextAlign.center,
                      style: FontService.style(
                        color: onSurf.withValues(alpha: 0.45),
                        fontSize: 15,
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: blocked.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    color: onSurf.withValues(alpha: 0.08),
                  ),
                  itemBuilder: (ctx, i) {
                    final name = blocked[i];
                    final bytes = avatars[name];
                    final initial =
                        name.isNotEmpty ? name[0].toUpperCase() : '?';

                    return ListTile(
                      leading: CircleAvatar(
                        radius: 22,
                        backgroundImage:
                            bytes != null ? MemoryImage(bytes) : null,
                        child: bytes == null
                            ? Text(
                                initial,
                                style: FontService.style(fontSize: 16),
                              )
                            : null,
                      ),
                      title: Text(
                        '@$name',
                        style: FontService.style(color: onSurf),
                      ),
                      subtitle: Text(
                        L.t('blocked_user'),
                        style: FontService.style(
                          fontSize: 12,
                          color: onSurf.withValues(alpha: 0.45),
                        ),
                      ),
                      trailing: TextButton(
                        onPressed: () => _unblock(name),
                        child: Text(
                          L.t('unblock'),
                          style: FontService.style(
                            color: Colors.greenAccent,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}