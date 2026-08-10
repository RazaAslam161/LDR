import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/glow_button.dart';
import 'package:miles/core/widgets/surface_panel.dart';
import 'package:miles/features/cycle/love_notes_pool.dart';

/// Editable preview for a pooled love note. The (male) sender can tweak the
/// wording, swap for a fresh note, or send it straight to chat. Nothing here
/// hints that it came from a pool — she just receives a normal message.
class LoveNotePreviewSheet extends StatefulWidget {
  const LoveNotePreviewSheet({
    required this.template, required this.recipientName, required this.onRegenerate, required this.onChangeName, required this.onSend, super.key,
  });

  /// Raw pooled paragraph, still holding the `{name}` placeholder.
  final String template;
  final String recipientName;
  final VoidCallback onRegenerate;

  /// Asks for a new name; returns it, or null if he backed out. The sheet stays
  /// open either way — closing it early would strand him and burn the note.
  final Future<String?> Function() onChangeName;
  final Future<void> Function(String) onSend;

  static Future<void> show(
    BuildContext context, {
    required String template,
    required String recipientName,
    required VoidCallback onRegenerate,
    required Future<String?> Function() onChangeName,
    required Future<void> Function(String) onSend,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => LoveNotePreviewSheet(
        template: template,
        recipientName: recipientName,
        onRegenerate: onRegenerate,
        onChangeName: onChangeName,
        onSend: onSend,
      ),
    );
  }

  @override
  State<LoveNotePreviewSheet> createState() => _LoveNotePreviewSheetState();
}

class _LoveNotePreviewSheetState extends State<LoveNotePreviewSheet> {
  late String _name = widget.recipientName;
  late final TextEditingController _ctrl =
      TextEditingController(text: renderLoveNote(widget.template, _name));
  bool _sending = false;
  bool _changingName = false;

  /// Swaps in a new name. Keeps the sheet open, so backing out of the prompt
  /// costs neither the note nor his edits — and substitutes into the CURRENT
  /// text rather than re-rendering the template, so a rename doesn't wipe
  /// whatever he has already typed.
  Future<void> _handleChangeName() async {
    if (_changingName) return; // the prompt is a channel hop; don't stack two
    _changingName = true;
    try {
      final name = await widget.onChangeName();
      if (name == null || !mounted) return;
      setState(() {
        if (_ctrl.text.contains(_name)) {
          // Normal case: swap in place so his edits survive.
          _ctrl.text = _ctrl.text.replaceAll(_name, name);
        } else if (widget.template.contains(kLoveNoteNameToken)) {
          // He has edited her name out of a paragraph that is written around
          // it. Re-render rather than leave the body silently unchanged while
          // the header claims the new name. Costs his edits, but the note has
          // to actually address the person it says it does.
          _ctrl.text = renderLoveNote(widget.template, name);
        }
        // Otherwise the note never carried a name — nothing to substitute.
        _name = name;
      });
    } finally {
      _changingName = false;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _handleSend() async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(_ctrl.text);
    } finally {
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SurfacePanel(
      radius: 24,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: MilesColors.gilt,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Header
              Text(
                'Love note 💌',
                style: GoogleFonts.fraunces(
                  fontSize: 20,
                  fontStyle: FontStyle.italic,
                  color: MilesColors.cream50,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'For $_name — edit before sending 😏',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: MilesColors.taupe,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _sending ? null : _handleChangeName,
                    style: TextButton.styleFrom(
                      foregroundColor: MilesColors.blush,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Change name',
                        style: TextStyle(fontSize: 12),),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Editable text area
              SurfacePanel(
                radius: 12,
                color: MilesColors.glassSubtle,
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: _ctrl,
                  maxLines: 8,
                  minLines: 5,
                  cursorColor: MilesColors.blush,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: MilesColors.cream100,
                    height: 1.6,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Buttons row
              Row(
                children: [
                  // Regenerate
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _sending
                          ? null
                          : () {
                              Navigator.pop(context);
                              widget.onRegenerate();
                            },
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('New note'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: MilesColors.taupe,
                        side: BorderSide(
                          color: MilesColors.gilt.withValues(alpha: 0.4),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Send
                  Expanded(
                    flex: 2,
                    child: GlowButton(
                      label: 'Send 💌',
                      color: MilesColors.blush,
                      loading: _sending,
                      onPressed: _sending ? null : _handleSend,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
