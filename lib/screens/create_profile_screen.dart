import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/font_service.dart';
import '../services/locale_service.dart';
import '../services/dyhanie_api.dart';
import '../services/avatar_cache.dart';
import 'recovery_phrase_screen.dart';

class CreateProfileScreen extends StatefulWidget {
  const CreateProfileScreen({super.key});

  @override
  State<CreateProfileScreen> createState() => _CreateProfileScreenState();
}

class _CreateProfileScreenState extends State<CreateProfileScreen> {
  final _controller = TextEditingController();
  final _picker = ImagePicker();
  Uint8List? _avatar;
  String? _error;
  bool _saving = false;

  Future<void> _pickAvatar() async {
    final img = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 70,
    );
    if (img != null) {
      final bytes = await img.readAsBytes();
      if (!mounted) return;
      setState(() => _avatar = bytes);
    }
  }

  Future<void> _save() async {
    final username = _controller.text.trim().toLowerCase();
    if (username.length < 3 || !RegExp(r'^[a-z0-9]+$').hasMatch(username)) {
      setState(() => _error = L.t('username_invalid'));
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await DyhanieApi.instance.connect();

      // понятная проверка имени до register
      final taken = await DyhanieApi.instance.usernameExists(username);
      if (taken) {
        if (!mounted) return;
        setState(() {
          _error = L.t('username_taken'); // или ваш ключ
          _saving = false;
        });
        return;
      }

      await DyhanieApi.instance.usernameRegister(username);
      await DyhanieApi.instance.sessionBind(username);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('username', username);

      if (_avatar != null) {
        final b64 = base64Encode(_avatar!);
        await prefs.setString('avatar', b64);
        await AvatarCache.saveBytes(
          username,
          _avatar!,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );
        try {
          await DyhanieApi.instance.avatarSet(b64);
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Профиль создан. Аватар на сервер не загрузился: $e',
              ),
            ),
          );
        }
      }

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => const RecoveryPhraseScreen(
            forceComplete: true,
            popOnDone: false,
          ),
        ),
      );
    } on TimeoutException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'timeout: $e';
        _saving = false;
      });
    } catch (e) {
      if (!mounted) return;
      final s = e.toString();
      setState(() {
        // не смешивать с «имя занято», если это аватар
        if (s.contains('AVATAR')) {
          _error = L.t('error'); // или avatar_upload_failed
        } else if (s.contains('EXISTS') ||
            s.contains('TAKEN') ||
            s.contains('USERNAME')) {
          _error = L.t('username_taken');
        } else {
          _error = s;
        }
        _saving = false;
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final onSurf = Theme.of(context).colorScheme.onSurface;

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 40),
              Text(
                L.t('profile'),
                style: FontService.style(
                  fontSize: 28,
                  fontWeight: FontWeight.w300,
                  color: onSurf,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                L.t('profile_subtitle'),
                textAlign: TextAlign.center,
                style: FontService.style(
                  fontSize: 14,
                  color: onSurf.withValues(alpha: 0.55),
                ),
              ),
              const SizedBox(height: 40),
              GestureDetector(
                onTap: _pickAvatar,
                child: CircleAvatar(
                  radius: 55,
                  backgroundColor: onSurf.withValues(alpha: 0.08),
                  backgroundImage: _avatar != null ? MemoryImage(_avatar!) : null,
                  child: _avatar == null
                      ? Icon(Icons.add_a_photo, color: onSurf.withValues(alpha: 0.55), size: 32)
                      : null,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                L.t('avatar_optional'),
                style: FontService.style(
                  fontSize: 13,
                  color: onSurf.withValues(alpha: 0.4),
                ),
              ),
              const SizedBox(height: 40),
              TextField(
                controller: _controller,
                style: FontService.style(fontSize: 18, color: onSurf),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9]')),
                ],
                decoration: InputDecoration(
                  labelText: L.t('username'),
                  labelStyle: TextStyle(color: onSurf.withValues(alpha: 0.55)),
                  errorText: _error,
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: onSurf.withValues(alpha: 0.25)),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: onSurf),
                  ),
                ),
                onSubmitted: (_) => _save(),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: onSurf,
                    foregroundColor: bg,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: bg,
                          ),
                        )
                      : Text(
                          L.t('continue'),
                          style: FontService.style(fontSize: 16, color: bg),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}