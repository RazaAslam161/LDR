import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:miles/core/app/release_gate.dart';
import 'package:miles/core/services/update_service.dart';
import 'package:miles/core/ui/theme.dart';

/// The download-and-install flow, shared by the two places an update surfaces:
/// the terminal block screen (a client below `min_build`, which cannot go on)
/// and a dismissible prompt inside the running app (a client merely behind
/// `latest_build`). [mandatory] hides the "Later" affordance for the first.
Future<void> showUpdateSheet(BuildContext context, {bool mandatory = false}) {
  return showModalBottomSheet<void>(
    context: context,
    isDismissible: !mandatory,
    enableDrag: !mandatory,
    backgroundColor: MilesColors.night,
    isScrollControlled: true,
    builder: (_) => PopScope(
      canPop: !mandatory,
      child: _UpdateSheet(mandatory: mandatory),
    ),
  );
}

enum _Stage { idle, needsPermission, downloading, installing, failed }

class _UpdateSheet extends StatefulWidget {
  const _UpdateSheet({required this.mandatory});

  final bool mandatory;

  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> {
  final _service = UpdateService();
  _Stage _stage = _Stage.idle;
  double _progress = 0;
  String? _error;
  File? _apk;

  @override
  void initState() {
    super.initState();
    // Re-attach to a transfer already running. The sheet is disposed every time
    // the app is backgrounded (the cover swaps the widget tree), so arriving to
    // find bytes already moving is the NORMAL case, not an edge one.
    UpdateService.progress.addListener(_onProgress);
    if (UpdateService.isDownloading) {
      _stage = _Stage.downloading;
      _progress = UpdateService.progress.value;
      unawaited(_attach());
    } else if (UpdateService.ready != null) {
      _apk = UpdateService.ready;
    }
  }

  void _onProgress() {
    if (mounted) setState(() => _progress = UpdateService.progress.value);
  }

  /// Await the transfer already running, rather than starting a second one.
  ///
  /// Stops at the finished file and does NOT install: the user backgrounded the
  /// app, so throwing the system installer in front of them the moment they
  /// return is not something they asked for. The sheet shows a ready state and
  /// they tap.
  Future<void> _attach() async {
    try {
      final apk = await _service.start();
      if (!mounted) return;
      setState(() {
        _apk = apk;
        _stage = _Stage.idle;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _error = e is Exception ? e.toString() : 'The download did not finish.';
      });
    }
  }

  @override
  void dispose() {
    UpdateService.progress.removeListener(_onProgress);
    // Deliberately NOT cancelling. This runs every time the app is backgrounded
    // — the cover raise disposes the whole tree — and cancelling here is what
    // threw away a nearly-complete 219 MB download when the user glanced at
    // another app. The transfer belongs to the service now and keeps going; an
    // explicit Cancel is the only thing that stops it.
    super.dispose();
  }

  Future<void> _start() async {
    // A second tap while a download or install is already under way would start
    // a concurrent write to the same file. Ignore it.
    if (_stage == _Stage.downloading || _stage == _Stage.installing) return;

    if (!await _service.canInstall()) {
      if (mounted) setState(() => _stage = _Stage.needsPermission);
      return;
    }

    // Reuse a file already downloaded this session — the common case is a user
    // who backed out of the system installer and tapped again, and re-fetching
    // 220 MB for that would be absurd.
    var apk = _apk;
    if (apk == null || !apk.existsSync()) {
      setState(() {
        _stage = _Stage.downloading;
        _progress = 0;
        _error = null;
      });
      try {
        // start(), not download(): the service owns the transfer so it survives
        // this sheet being disposed, and progress arrives through the listener
        // wired in initState rather than a closure over this State.
        apk = await _service.start();
        _apk = apk;
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _stage = _Stage.failed;
          _error =
              e is Exception ? e.toString() : 'The download did not finish.';
        });
        return;
      }
    }

    if (!mounted) return;
    setState(() => _stage = _Stage.installing);
    try {
      await _service.install(apk);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _error = 'The installer could not be opened.';
      });
      return;
    }
    // install() returns the instant the system installer is in front, so leaving
    // the sheet on a spinner would strand anyone who backs out of it — fatal for
    // the mandatory sheet, which cannot be dismissed. Drop back to an actionable
    // state; the downloaded file is kept so a retry installs without re-fetching.
    if (mounted) setState(() => _stage = _Stage.idle);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.system_update, color: MilesColors.ember, size: 40),
            const SizedBox(height: 16),
            Text(
              widget.mandatory ? 'Update required' : 'Update available',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _subtitle(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: MilesColors.cream50,
                fontSize: 14,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 24),
            ..._body(),
          ],
        ),
      ),
    );
  }

  String _subtitle() {
    switch (_stage) {
      case _Stage.needsPermission:
        return 'Allow installing updates for this app, then tap Update again.';
      case _Stage.downloading:
        return _progress > 0
            ? '${(_progress * 100).round()}%'
            : 'Starting download…';
      case _Stage.installing:
        return 'Opening the installer…';
      case _Stage.failed:
        return _error ?? 'Something went wrong.';
      case _Stage.idle:
        final v = ReleaseGate.latestVersionName;
        return v != null && v.isNotEmpty
            ? 'Version $v is ready to install.'
            : 'A newer version is ready to install.';
    }
  }

  List<Widget> _body() {
    switch (_stage) {
      case _Stage.downloading:
        return [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _progress > 0 ? _progress : null,
              minHeight: 6,
              backgroundColor: MilesColors.surface2,
              valueColor:
                  const AlwaysStoppedAnimation<Color>(MilesColors.ember),
            ),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () {
              _service.cancel();
              if (mounted) setState(() => _stage = _Stage.idle);
            },
            child: const Text('Cancel', style: TextStyle(color: MilesColors.cream50)),
          ),
        ];
      case _Stage.installing:
        return const [
          Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation<Color>(MilesColors.ember),
              ),
            ),
          ),
        ];
      case _Stage.needsPermission:
        return [
          _primary('Open settings', () async {
            await _service.openInstallSettings();
            if (mounted) setState(() => _stage = _Stage.idle);
          }),
          if (!widget.mandatory) _later(),
        ];
      case _Stage.failed:
        return [
          _primary('Try again', _start),
          if (!widget.mandatory) _later(),
        ];
      case _Stage.idle:
        return [
          _primary('Update now', _start),
          if (!widget.mandatory) _later(),
        ];
    }
  }

  Widget _primary(String label, VoidCallback onPressed) => ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: MilesColors.ember,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Text(label,
            style:
                const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),),
      );

  Widget _later() => TextButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Later',
            style: TextStyle(color: MilesColors.cream50),),
      );
}
