import 'package:flutter/material.dart';
import 'package:miles/core/ui/theme.dart';

/// Label above a field, with the hint and the error that belong to it.
///
/// Three things were wrong with the version this replaces, and all three were
/// wrong on every screen that used it:
///
///   * `hint` was accepted and never rendered. Callers passed it, nothing
///     appeared, and the guidance that would have told someone the password
///     rules BEFORE they submitted was silently dropped on the floor.
///   * The label was 12px at 50% opacity over a dark surface — under the 4.5:1
///     contrast floor, and below the 12px body minimum once a user has the
///     system font scaled down.
///   * There was nowhere to put a per-field error, so every screen showed one
///     banner at the bottom for the whole form. "Use at least 8 characters"
///     appeared under a submit button while the field it was about sat above,
///     unmarked. Forms guidance calls that out specifically: an invalid field
///     needs its own message, attached to it.
class LabeledField extends StatelessWidget {
  const LabeledField({
    required this.label,
    required this.child,
    super.key,
    this.hint,
    this.error,
  });

  final String label;
  final Widget child;

  /// Guidance shown before anything goes wrong — format, rules, why we ask.
  final String? hint;

  /// This field's own error. Replaces [hint] while it is set, so the row does
  /// not grow and shove the rest of the form down as the user types.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final invalid = error != null;

    return Semantics(
      // The label, the guidance and the failure arrive as one announcement,
      // in that order, instead of three unrelated strings the user has to
      // reassemble by swiping between them.
      label: label,
      hint: error ?? hint,
      textField: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              label,
              // ExcludeSemantics on the visual copies: the Semantics wrapper
              // above already says all of this, and without it a screen reader
              // reads the label twice and the error twice.
              style: text.labelSmall?.copyWith(
                color: invalid
                    ? Theme.of(context).colorScheme.error
                    : MilesColors.taupe,
              ),
            ),
          ),
          ExcludeSemantics(child: child),
          if (invalid || hint != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (invalid) ...[
                    Icon(
                      Icons.error_outline,
                      size: 14,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      error ?? hint!,
                      style: text.labelSmall?.copyWith(
                        color: invalid
                            ? Theme.of(context).colorScheme.error
                            : MilesColors.faint,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
