import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:miles/core/theme.dart';

/// The trace, on the phone that produced it.
///
/// The server copy is the one that gets correlated with the partner's, but it
/// needs connectivity, a couple and a working insert — and "nothing is being
/// uploaded" is itself one of the outcomes worth being able to see. This view
/// reads the in-memory ring, so it works when everything else does not, which
/// is the only condition under which anyone opens it.
class DiagScreen extends StatefulWidget {
  const DiagScreen({super.key});

  @override
  State<DiagScreen> createState() => _DiagScreenState();
}

class _DiagScreenState extends State<DiagScreen> {
  DiagArea? _filter;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // The interesting case is watching a call fail while the screen is open, so
    // it repaints on its own. One second is far below the rate events arrive
    // and far above the rate a person reads.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  List<DiagEvent> get _events {
    final all = Diag.recent.reversed.toList();
    return _filter == null ? all : all.where((e) => e.area == _filter).toList();
  }

  Future<void> _copy() async {
    // The whole ring, not the filtered view: whoever receives this needs the
    // events around the failure, and the filter was chosen to find it, not to
    // describe it.
    await Clipboard.setData(ClipboardData(text: Diag.dump()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${Diag.recent.length} events copied')),
    );
  }

  Future<void> _copyFromDisk() async {
    final text = await Diag.readFile();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text.isEmpty
            ? 'Nothing on disk yet'
            : '${text.length ~/ 1024}KB copied, including previous runs'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final events = _events;
    return Scaffold(
      backgroundColor: MilesColors.night,
      appBar: AppBar(
        backgroundColor: MilesColors.night,
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Copy this run',
            icon: const Icon(Icons.copy_all),
            onPressed: _copy,
          ),
          IconButton(
            tooltip: 'Copy everything on disk',
            icon: const Icon(Icons.save_alt),
            onPressed: _copyFromDisk,
          ),
        ],
      ),
      body: Column(
        children: [
          SwitchListTile(
            value: Diag.enabled,
            activeColor: MilesColors.ember,
            title: const Text('Record diagnostics',
                style: TextStyle(color: MilesColors.cream50)),
            subtitle: const Text(
              'Call, delivery and presence events. Never message text, '
              'photos or location.',
              style: TextStyle(color: MilesColors.taupe, fontSize: 12),
            ),
            onChanged: (v) async {
              await Diag.setEnabled(v);
              if (mounted) setState(() {});
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _chip('all', _filter == null, () => setState(() => _filter = null)),
                        for (final a in DiagArea.values)
                          _chip(a.name, _filter == a,
                              () => setState(() => _filter = a)),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.delete_outline,
                      color: MilesColors.faint),
                  onPressed: () async {
                    await Diag.clear();
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${events.length} shown · ${Diag.recent.length} held · '
                '${Diag.uploadedCount} uploaded'
                '${Diag.droppedCount > 0 ? ' · ${Diag.droppedCount} dropped' : ''}'
                '${Diag.lastUploadError != null ? ' · upload failing: ${Diag.lastUploadError}' : ''}',
                style: TextStyle(
                  // Upload failure is the one number on this screen that
                  // changes what the person holding the phone should do: it
                  // means collect the disk copy by hand, because the server
                  // will have nothing.
                  color: Diag.lastUploadError == null
                      ? MilesColors.faint
                      : MilesColors.blush,
                  fontSize: 11,
                ),
              ),
            ),
          ),
          const Divider(height: 1, color: MilesColors.surface2),
          Expanded(
            child: events.isEmpty
                ? const Center(
                    child: Text('Nothing recorded yet',
                        style: TextStyle(color: MilesColors.faint)),
                  )
                : ListView.builder(
                    itemCount: events.length,
                    itemBuilder: (_, i) {
                      final e = events[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 3),
                        child: Text(
                          e.line,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            height: 1.35,
                            color: _colorFor(e),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          label: Text(label),
          selected: on,
          onSelected: (_) => onTap(),
          selectedColor: MilesColors.ember,
          backgroundColor: MilesColors.surface1,
          labelStyle: TextStyle(
            fontSize: 12,
            color: on ? MilesColors.night : MilesColors.taupe,
          ),
        ),
      );

  /// Failures in warm red, so a wall of monospace still has a shape. The
  /// convention is in the event NAME rather than a severity field — one less
  /// thing for a call site to get wrong.
  static Color _colorFor(DiagEvent e) {
    final n = e.name;
    if (n.contains('fail') || n.contains('error') || n.contains('timeout')) {
      return MilesColors.blush;
    }
    if (n.contains('connected') || n.contains('ok') || n.contains('ack')) {
      return MilesColors.emberSoft;
    }
    return MilesColors.cream200;
  }
}
