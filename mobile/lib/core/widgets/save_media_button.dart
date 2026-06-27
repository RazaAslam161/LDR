import 'package:flutter/material.dart';
import 'package:miles/core/theme.dart';

/// A small download icon that saves media on tap and shows brief SnackBar
/// feedback. Reused across chat bubbles, the media viewers, and the Touch
/// screen so all save actions look and behave the same.
class SaveMediaButton extends StatefulWidget {
  const SaveMediaButton({
    super.key,
    required this.onSave,
    this.color,
    this.size = 20,
    this.successMessage = 'Saved to your vault 🔒',
    this.failureMessage = 'Could not save to vault',
  });

  /// Performs the save; returns true on success.
  final Future<bool> Function() onSave;
  final Color? color;
  final double size;
  final String successMessage;
  final String failureMessage;

  @override
  State<SaveMediaButton> createState() => _SaveMediaButtonState();
}

class _SaveMediaButtonState extends State<SaveMediaButton> {
  bool _saving = false;

  Future<void> _tap() async {
    if (_saving) return;
    setState(() => _saving = true);
    final success = await widget.onSave();
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success ? widget.successMessage : widget.failureMessage,
          style: const TextStyle(fontFamily: 'Inter'),
        ),
        backgroundColor: success ? MilesColors.sage : MilesColors.ember,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? MilesColors.cream50;
    return GestureDetector(
      onTap: _tap,
      behavior: HitTestBehavior.opaque,
      child: _saving
          ? SizedBox(
              width: widget.size,
              height: widget.size,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
            )
          : Icon(Icons.download_rounded, size: widget.size, color: color),
    );
  }
}
