import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/glass_panel.dart';
import 'package:miles/core/widgets/glow_button.dart';

/// Editable preview for a pooled love note. The (male) sender can tweak the
/// wording, swap for a fresh note, or send it straight to chat. Nothing here
/// hints that it came from a pool — she just receives a normal message.
class LoveNotePreviewSheet extends StatefulWidget {
  const LoveNotePreviewSheet({
    super.key,
    required this.note,
    required this.onRegenerate,
    required this.onSend,
  });

  final String note;
  final VoidCallback onRegenerate;
  final Future<void> Function(String) onSend;

  static Future<void> show(
    BuildContext context, {
    required String note,
    required VoidCallback onRegenerate,
    required Future<void> Function(String) onSend,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => LoveNotePreviewSheet(
        note: note,
        onRegenerate: onRegenerate,
        onSend: onSend,
      ),
    );
  }

  @override
  State<LoveNotePreviewSheet> createState() => _LoveNotePreviewSheetState();
}

class _LoveNotePreviewSheetState extends State<LoveNotePreviewSheet> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.note);
  bool _sending = false;

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
    return GlassPanel(
      blur: MilesColors.blurLg,
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
              Text(
                'Edit before sending — she’ll never know 😏',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: MilesColors.taupe,
                ),
              ),
              const SizedBox(height: 16),

              // Editable text area
              GlassPanel(
                blur: MilesColors.blurSm,
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
