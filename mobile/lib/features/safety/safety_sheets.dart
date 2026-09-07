import 'package:flutter/material.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/safety/contact_pause.dart';
import 'package:miles/features/safety/report_service.dart';

/// The two safety surfaces, as sheets, so the same code answers from Settings,
/// from Chat and from the Gallery. Three copies of a report flow is how two of
/// them end up sending a different payload.

/// Report something.
///
/// [targetRef] is an id the operator can line up with a row — a message id, a
/// gallery item id — never content. There is nothing to show afterwards and
/// nothing is kept on the device: a list of "reports you filed about your
/// partner", on a phone that partner may pick up, is the most dangerous screen
/// this app could render.
Future<void> showReportSheet(
  BuildContext context, {
  required ReportTarget target,
  String? targetRef,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: MilesColors.surface1,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _ReportSheet(target: target, targetRef: targetRef),
  );
}

/// Pause being interrupted.
///
/// Every label here is neutral on purpose. Nothing says "block" and nothing
/// names the partner, because this screen may be read over the user's shoulder
/// by the person it is about — which is the same reason the mute itself is
/// silent server-side.
Future<void> showContactPauseSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: MilesColors.surface1,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _PauseSheet(),
  );
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet({required this.target, this.targetRef});

  final ReportTarget target;
  final String? targetRef;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  final _note = TextEditingController();
  ReportReason? _reason;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final reason = _reason;
    if (reason == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final note = _note.text.trim();
      await ReportService.submit(
        reason: reason,
        target: widget.target,
        targetRef: widget.targetRef,
        note: note.isEmpty ? null : note,
      );
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Thanks — that has been sent.')),
      );
    } on ReportRateLimited {
      if (mounted) {
        setState(() =>
            _error = "That's several reports today. Try again tomorrow.",);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = "That didn't go through. Try again.");
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
                child: Text(
                  'Report a problem',
                  style: TextStyle(
                      color: MilesColors.cream50,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,),
                ),
              ),
              // The honest version. Saying "we can't read your messages" would
              // be false — chat bodies only seal when the server flag is on and
              // the seal succeeds, and chat media is not encrypted at all.
              //
              // What IS end-to-end encrypted: Memory Threads, the text of Wish
              // Jar entries, message reactions, and the messages and notes
              // written during a separation.
              //
              // The Private Vault is NOT, and this comment claimed it was until
              // 2026-09-04 — `VaultRepository.saveMedia` calls `_uploadPlain`
              // and `personal_vault_items.content` is `text`. It has been
              // plaintext since build 60 by the owner's 2026-08-28 ruling. This
              // comment was one of eight places carrying that error, and being
              // a comment it was the one that taught the next person to repeat
              // it. THREAT-MODEL.md §1 is the list this must agree with; check
              // it against that table rather than against another comment.
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 14),
                child: Text(
                  'This records who, when and why — not what was sent. Some of '
                  'what the two of you send is encrypted so nobody here can '
                  'open it, and the rest is not read. If something specific '
                  'matters, put it in the note.',
                  style: TextStyle(
                      color: MilesColors.taupe, fontSize: 12, height: 1.5,),
                ),
              ),
              // Hand-rolled rather than RadioListTile: its groupValue/onChanged
              // pair is deprecated on this Flutter, and a deprecation warning
              // in a gate that must stay at zero is not worth the widget.
              for (final reason in ReportReason.values)
                ListTile(
                  enabled: !_busy,
                  dense: true,
                  leading: Icon(
                    _reason == reason
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: _reason == reason
                        ? MilesColors.ember
                        : MilesColors.faint,
                  ),
                  title: Text(reason.label,
                      style: const TextStyle(
                          color: MilesColors.cream50, fontSize: 14,),),
                  onTap: () => setState(() => _reason = reason),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: TextField(
                  controller: _note,
                  maxLines: 3,
                  maxLength: 1000,
                  enabled: !_busy,
                  style: const TextStyle(
                      color: MilesColors.cream50, fontSize: 14,),
                  decoration: const InputDecoration(
                    hintText: 'Anything we should know (optional)',
                  ),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(_error!,
                      style: const TextStyle(
                          color: MilesColors.ember, fontSize: 12,),),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: _busy ? null : () => Navigator.pop(context),
                      child: const Text('Cancel',
                          style: TextStyle(color: MilesColors.taupe),),
                    ),
                    const Spacer(),
                    FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: MilesColors.ember,),
                      onPressed: _reason == null || _busy ? null : _send,
                      child: Text(_busy ? 'Sending…' : 'Send report'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PauseSheet extends StatefulWidget {
  const _PauseSheet();

  @override
  State<_PauseSheet> createState() => _PauseSheetState();
}

class _PauseSheetState extends State<_PauseSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _apply(int? minutes) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (minutes == 0) {
        await ContactPause.resume();
      } else {
        await ContactPause.pause(minutes);
      }
      if (mounted) Navigator.pop(context);
    } catch (e, st) {
      // Named, not swallowed. mute_partner raises 'no partner' when the couple
      // has one member left, and the generic sentence turned that into a row
      // that appeared to do nothing at all — the owner reported exactly this
      // ("pressed 1 hour, nothing happened") while alone in a couple of one.
      ErrorReporter.report(e, st, kind: 'contact-pause');
      final noPartner = e.toString().contains('no partner');
      if (mounted) {
        setState(() => _error = noPartner
            ? 'There is no one on the other side of this connection, so '
                'there is nothing to pause.'
            : "That didn't go through. Try again.");
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 0 is the resume, so one handler covers every row.
    const options = <(String, int?)>[
      ('For 1 hour', 60),
      ('For 8 hours', 480),
      ('For 24 hours', 1440),
      ('Until I turn it back on', null),
    ];
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Text(
              'Pause notifications',
              style: TextStyle(
                  color: MilesColors.cream50,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              'Reaches, nudges and calls stop notifying this phone — that '
              'part is enforced on the server. Messages still arrive and '
              'still show as delivered to your partner; this phone just '
              'stays quiet about them until you open the app. Nothing is '
              'deleted, nobody is told, and you can turn it off whenever '
              'you want.',
              style: TextStyle(
                  color: MilesColors.taupe, fontSize: 12, height: 1.5,),
            ),
          ),
          for (final (label, minutes) in options)
            ListTile(
              enabled: !_busy,
              leading: const Icon(Icons.notifications_off_outlined,
                  color: MilesColors.gilt,),
              title: Text(label,
                  style: const TextStyle(color: MilesColors.cream50),),
              onTap: () => _apply(minutes),
            ),
          if (ContactPause.isActive)
            ListTile(
              enabled: !_busy,
              leading: const Icon(Icons.notifications_active_outlined,
                  color: MilesColors.sage,),
              title: const Text('Turn notifications back on',
                  style: TextStyle(color: MilesColors.sage),),
              onTap: () => _apply(0),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(_error!,
                  style: const TextStyle(
                      color: MilesColors.ember, fontSize: 12,),),
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
