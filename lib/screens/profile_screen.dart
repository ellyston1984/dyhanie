import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/avatar_cache.dart';
import '../services/dyhanie_api.dart';
import '../services/font_service.dart';
import '../services/locale_service.dart';
import '../services/unread_chats_service.dart';
import 'welcome_screen.dart';

class ProfileScreen extends StatefulWidget {
  final String username;
  final Uint8List? avatarBytes;

  const ProfileScreen({
    super.key,
    required this.username,
    this.avatarBytes,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  /// Свой аватар в prefs (home / старый код).
  static const avatarKey = 'avatar';

  final _picker = ImagePicker();
  final _nameCtrl = TextEditingController();

  Uint8List? avatarBytes;
  bool saving = false;
  bool deleting = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl.text = widget.username;
    avatarBytes = widget.avatarBytes;
    _loadAvatar();
  }

  Future<void> _loadAvatar() async {
    // 1) свой ключ avatar
    final prefs = await SharedPreferences.getInstance();
    var b64 = prefs.getString(avatarKey);
    if (b64 != null && b64.isNotEmpty) {
      if (b64.contains(',')) b64 = b64.split(',').last;
      try {
        final bytes = base64Decode(b64);
        if (mounted) setState(() => avatarBytes = bytes);
        return;
      } catch (_) {}
    }

    // 2) кэш avatar_<me>
    final cached = await AvatarCache.load(widget.username);
    if (cached != null && mounted) {
      setState(() => avatarBytes = cached);
      return;
    }

    // 3) сервер (если локально пусто)
    try {
      await DyhanieApi.instance.connect();
      final remote = await AvatarCache.fetch(
        widget.username,
        forceNetwork: true,
      );
      if (remote != null && mounted) {
        setState(() => avatarBytes = remote);
        await prefs.setString(avatarKey, base64Encode(remote));
      }
    } catch (_) {}
  }

  /// Локально + кэш + сервер.
  Future<void> _persistAvatar(Uint8List bytes, String username) async {
    // не раздувать payload
    // при pick уже лучше: maxWidth: 512, imageQuality: 70

    final b64 = base64Encode(bytes);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(avatarKey, b64);
    await AvatarCache.saveBytes(username, bytes);

    try {
      await DyhanieApi.instance.connect();
      await DyhanieApi.instance.sessionBind(username.toLowerCase().trim());
      await DyhanieApi.instance.avatarSet(b64);
      await AvatarCache.saveBytes(
        username,
        bytes,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Аватар локально, на сервер: $e')),
        );
      }
      rethrow; // или не rethrow, но UI должен знать
    }
  }

  Future<void> _changeAvatar() async {
    final img = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 70,
    );
    if (img == null) return;

    final bytes = await img.readAsBytes();
    if (!mounted) return;
    setState(() => avatarBytes = bytes);

    try {
      await _persistAvatar(bytes, widget.username);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L.t('avatar_updated'))),
      );
    } catch (_) {
      // ошибка уже в SnackBar из _persistAvatar
    }
  }
  
  Future<void> _save() async {
    final name = _nameCtrl.text.trim().toLowerCase();
    if (name.length < 3 || !RegExp(r'^[a-z0-9]+$').hasMatch(name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L.t('enter_username'))),
      );
      return;
    }

    setState(() => saving = true);
    try {
      final old = widget.username.toLowerCase();
      await DyhanieApi.instance.connect();

      if (name != old) {
        await DyhanieApi.instance.usernameRename(old, name);
        await DyhanieApi.instance.sessionBind(name);
      } else {
        await DyhanieApi.instance.sessionBind(name);
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('username', name);

      if (avatarBytes != null) {
        await _persistAvatar(avatarBytes!, name);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L.t('saved'))),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${L.t('save_error')}: $e')),
      );
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _deleteEverything() async {
    final scheme = Theme.of(context).colorScheme;
    final onSurf = scheme.onSurface;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: scheme.surfaceContainerHigh,
        title: Text(
          L.t('delete_all_title'),
          style: FontService.style(color: onSurf),
        ),
        content: Text(
          L.tParams('delete_all_body_server', {'name': widget.username}),
          style: FontService.style(
            color: onSurf.withValues(alpha: 0.8),
            height: 1.4,
          ),
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
              L.t('delete'),
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => deleting = true);
    final uname = widget.username.toLowerCase();

    try {
      try {
        await DyhanieApi.instance.connect();
        await DyhanieApi.instance.sessionBind(uname);
        await DyhanieApi.instance.usernameDelete(uname);
      } catch (_) {}

      try {
        await DyhanieApi.instance.disconnect();
      } catch (_) {}

      try {
        await UnreadChatsService.instance.load();
        for (final id in UnreadChatsService.instance.snapshot.keys.toList()) {
          await UnreadChatsService.instance.clear(id);
        }
      } catch (_) {}

      try {
        await AvatarCache.remove(uname);
      } catch (_) {}

      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    } finally {
      if (mounted) setState(() => deleting = false);
    }

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => const WelcomeScreen(goHomeOnContinue: false),
      ),
      (_) => false,
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final onSurf = Theme.of(context).colorScheme.onSurface;
    final busy = saving || deleting;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        title: Text(
          L.t('profile'),
          style: FontService.style(fontSize: 18, color: onSurf),
        ),
        iconTheme: IconThemeData(color: onSurf),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
        children: [
          const SizedBox(height: 12),
          Center(
            child: Column(
              children: [
                GestureDetector(
                  onTap: busy ? null : _changeAvatar,
                  child: CircleAvatar(
                    radius: 48,
                    backgroundColor: onSurf.withValues(alpha: 0.1),
                    backgroundImage:
                        avatarBytes != null ? MemoryImage(avatarBytes!) : null,
                    child: avatarBytes == null
                        ? Icon(
                            Icons.add_a_photo_outlined,
                            color: onSurf.withValues(alpha: 0.4),
                            size: 28,
                          )
                        : null,
                  ),
                ),
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: busy ? null : _changeAvatar,
                  child: Text(
                    L.t('change_avatar'),
                    style: FontService.style(
                      fontSize: 13,
                      color: onSurf.withValues(alpha: 0.4),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 36),
          Text(
            L.t('username'),
            style: FontService.style(
              fontSize: 12,
              color: onSurf.withValues(alpha: 0.4),
            ),
          ),
          TextField(
            controller: _nameCtrl,
            enabled: !busy,
            style: FontService.style(fontSize: 18, color: onSurf),
            cursorColor: onSurf,
            decoration: InputDecoration(
              border: InputBorder.none,
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: onSurf.withValues(alpha: 0.25)),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: onSurf.withValues(alpha: 0.55)),
              ),
            ),
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: TextButton(
              style: TextButton.styleFrom(
                foregroundColor: onSurf,
                backgroundColor: Colors.transparent,
                elevation: 0,
                shadowColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.zero,
                ),
              ),
              onPressed: busy ? null : _save,
              child: saving
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: onSurf,
                      ),
                    )
                  : Text(
                      L.t('save'),
                      style: FontService.style(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: onSurf,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: TextButton(
              style: TextButton.styleFrom(
                foregroundColor: Colors.redAccent,
                backgroundColor: Colors.transparent,
                elevation: 0,
                shadowColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.zero,
                ),
              ),
              onPressed: busy ? null : _deleteEverything,
              child: deleting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.redAccent,
                      ),
                    )
                  : Text(
                      L.t('delete_all'),
                      style: FontService.style(
                        fontSize: 15,
                        color: Colors.redAccent,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            L.t('delete_all_footer'),
            textAlign: TextAlign.center,
            style: FontService.style(
              fontSize: 11,
              height: 1.35,
              color: onSurf.withValues(alpha: 0.35),
            ),
          ),
        ],
      ),
    );
  }
}