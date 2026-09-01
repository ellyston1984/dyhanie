import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/dyhanie_key/dyhanie_key.dart';
import '../services/font_service.dart';
import '../services/locale_service.dart';
import '../services/icon_style_service.dart';
import 'home_screen.dart';

/// Показ резервной фразы (create). Заглушка без реальной крипты.
class RecoveryPhraseScreen extends StatefulWidget {
  /// После «Продолжить» сделать Navigator.pop.
  final bool popOnDone;

  /// true = первый вход: нельзя закрыть без чекбокса + Continue.
  final bool forceComplete;

  final VoidCallback? onDone;

  const RecoveryPhraseScreen({
    super.key,
    this.popOnDone = true,
    this.forceComplete = false,
    this.onDone,
  });

  @override
  State<RecoveryPhraseScreen> createState() => _RecoveryPhraseScreenState();
}

class _RecoveryPhraseScreenState extends State<RecoveryPhraseScreen> {
  List<String>? _words;
  bool _loading = true;
  bool _confirmed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final words = await dyhanieKey.generateRecoveryPhrase();
    if (!mounted) return;
    setState(() {
      _words = words;
      _loading = false;
    });
  }

  Future<void> _copyAll() async {
    final w = _words;
    if (w == null) return;
    await Clipboard.setData(ClipboardData(text: w.join(' ')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L.t('phrase_copied'))),
    );
  }

  Future<void> _continue() async {
    if (!_confirmed) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('recovery_phrase_shown', true);
    // Слова не сохраняем — stub. Реальный протокол: secure storage / бумага.
    if (!mounted) return;
    if (widget.onDone != null) {
      widget.onDone!();
    } else if (widget.popOnDone) {
      Navigator.pop(context, true);
    } else if (widget.forceComplete) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final onSurf = scheme.onSurface;
    final words = _words;

    return PopScope(
      canPop: !widget.forceComplete,
      child: Scaffold(
        backgroundColor: bg,
        appBar: AppBar(
          backgroundColor: bg,
          automaticallyImplyLeading: !widget.forceComplete,
          title: Text(
            L.t('recovery_phrase_title'),
            style: FontService.style(fontSize: 18, color: onSurf),
          ),
          iconTheme: IconThemeData(color: onSurf),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        L.t('recovery_phrase_hint'),
                        style: FontService.style(
                          color: onSurf.withValues(alpha: 0.65),
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: GridView.builder(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 10,
                            childAspectRatio: 2.6,
                          ),
                          itemCount: words?.length ?? 0,
                          itemBuilder: (_, i) {
                            return Container(
                              alignment: Alignment.centerLeft,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
                              decoration: BoxDecoration(
                                color: onSurf.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${i + 1}. ${words![i]}',
                                style: FontService.style(
                                  color: onSurf,
                                  fontSize: 13,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          },
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _copyAll,
                        icon: Icon(
                          AppIcons.copy,
                          color: onSurf.withValues(alpha: 0.7),
                        ),
                        label: Text(
                          L.t('copy'),
                          style: FontService.style(color: onSurf),
                        ),
                      ),
                      CheckboxListTile(
                        value: _confirmed,
                        onChanged: (v) =>
                            setState(() => _confirmed = v ?? false),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          L.t('recovery_phrase_confirm'),
                          style: FontService.style(
                            color: onSurf,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: _confirmed ? _continue : null,
                        child: Text(L.t('continue')),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}