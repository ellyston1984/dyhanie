import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/dyhanie_key/dyhanie_key.dart';
import '../services/dyhanie_key/protocol.dart';
import '../services/font_service.dart';
import '../services/locale_service.dart';
import 'pin_setup_screen.dart';

class RestorePhraseScreen extends StatefulWidget {
  final VoidCallback? onRestored;

  const RestorePhraseScreen({
    super.key,
    this.onRestored,
  });

  @override
  State<RestorePhraseScreen> createState() => _RestorePhraseScreenState();
}

class _RestorePhraseScreenState extends State<RestorePhraseScreen> {
  static const _n = DyhanieProtocol.wordCount;

  late final List<TextEditingController> _ctrls;
  late final List<FocusNode> _nodes;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _ctrls = List.generate(_n, (_) => TextEditingController());
    _nodes = List.generate(_n, (_) => FocusNode());
  }

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  List<String> _words() => _ctrls
      .map((c) => c.text.trim().toLowerCase())
      .where((w) => w.isNotEmpty)
      .toList();

  void _applyPaste(String raw) {
    final words = raw
        .split(RegExp(r'[\s,;]+'))
        .map((w) => w.trim().toLowerCase())
        .where((w) => w.isNotEmpty)
        .take(_n)
        .toList();
    if (words.length < 2) return;
    for (var i = 0; i < _n; i++) {
      _ctrls[i].text = i < words.length ? words[i] : '';
    }
    setState(() {});
    final next = words.length < _n ? words.length : _n - 1;
    _nodes[next].requestFocus();
  }

  Future<void> _resetLocalAccount() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('username');
    await prefs.remove('avatar');
    await prefs.remove('pin_code');
    await prefs.remove('pin_hash');
    await prefs.remove('pin_enabled');
    await prefs.remove('pin');
    final keys = prefs.getKeys().toList();
    for (final k in keys) {
      if (k.startsWith('chat_history_') ||
          k.startsWith('chat_cfg_') ||
          k == 'chats_pinned' ||
          k == 'chats_notes') {
        await prefs.remove(k);
      }
    }
    await prefs.setBool('recovery_phrase_shown', true);
  }

  Future<void> _submit() async {
    final words = _words();
    if (words.length != _n) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L.t('restore_phrase_need_6'))),
      );
      return;
    }

    setState(() => _busy = true);
    final ok = await dyhanieKey.restoreFromPhrase(words);
    if (!mounted) return;
    setState(() => _busy = false);

    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L.t('restore_phrase_fail'))),
      );
      return;
    }

    await _resetLocalAccount();
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L.t('restore_phrase_ok'))),
    );
    widget.onRestored?.call();

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const PinSetupScreen()),
      (_) => false,
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
          L.t('restore_phrase_title'),
          style: FontService.style(fontSize: 18, color: onSurf),
        ),
        iconTheme: IconThemeData(color: onSurf),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                L.t('restore_phrase_hint'),
                style: FontService.style(
                  color: onSurf.withValues(alpha: 0.65),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 2.6,
                  ),
                  itemCount: _n,
                  itemBuilder: (_, i) {
                    return TextField(
                      controller: _ctrls[i],
                      focusNode: _nodes[i],
                      textInputAction: i == _n - 1
                          ? TextInputAction.done
                          : TextInputAction.next,
                      autocorrect: false,
                      enableSuggestions: false,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z\s]')),
                      ],
                      style: FontService.style(color: onSurf, fontSize: 15),
                      onChanged: (v) {
                        if (v.contains(' ') || v.contains('\n')) {
                          _applyPaste(v);
                          return;
                        }
                        setState(() {});
                      },
                      onSubmitted: (_) {
                        if (i < _n - 1) {
                          _nodes[i + 1].requestFocus();
                        } else {
                          _submit();
                        }
                      },
                      decoration: InputDecoration(
                        prefixText: '${i + 1}.  ',
                        prefixStyle: FontService.style(
                          color: onSurf.withValues(alpha: 0.4),
                          fontSize: 13,
                        ),
                        filled: true,
                        fillColor: onSurf.withValues(alpha: 0.06),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(L.t('restore_phrase_action')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
