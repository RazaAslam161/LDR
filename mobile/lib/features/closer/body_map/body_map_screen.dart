import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/features/closer/body_map/body_map_repository.dart';
import 'package:miles/features/closer/body_map/body_silhouette_painter.dart';

/// Body Map — a stylized abstract silhouette where each partner pins spots
/// they love to be touched / want explored, each with a 1-line note.
///
/// Compliance: silhouette is an artistic line drawing (see §F7), never a photo.
/// Notes are E2EE; pins are color-coded by partner.
class BodyMapScreen extends ConsumerStatefulWidget {
  const BodyMapScreen({super.key});

  @override
  ConsumerState<BodyMapScreen> createState() => _BodyMapScreenState();
}

class _BodyMapScreenState extends ConsumerState<BodyMapScreen> {
  bool _loading = true;
  String? _error;
  List<BodyMapPin> _pins = const [];
  String? _selectedPinId;

  // navy950 background colors (constants mirror MilesColors).
  static const _meColor = Color(0xFFEF6F58); // coral500
  static const _themColor = Color(0xFFF5EFE6); // cream100

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider);
    final couple = session.couple;
    final me = session.profile;
    final partner = session.partner;
    if (couple == null || me == null || partner == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Link your partner to start mapping together.';
        });
      }
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await BodyMapRepository.ensureSharedKey(session);
      final pins = await BodyMapRepository.fetchPins(coupleId: couple.id);
      if (!mounted) return;
      setState(() {
        _pins = pins;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _addPinAt(Offset local, Size canvasSize) async {
    final session = ref.read(sessionProvider);
    final me = session.profile;
    final couple = session.couple;
    if (me == null || couple == null) return;

    final x = (local.dx / canvasSize.width).clamp(0.02, 0.98);
    final y = (local.dy / canvasSize.height).clamp(0.02, 0.98);

    final note = await showDialog<String>(
      context: context,
      builder: (ctx) => const _PinNoteDialog(),
    );
    if (note == null || note.trim().isEmpty) return;

    try {
      await BodyMapRepository.addPin(
        coupleId: couple.id,
        authorId: me.id,
        x: x,
        y: y,
        note: note.trim(),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not add pin: $e')),
      );
    }
  }

  Future<void> _deleteSelected() async {
    final pin = _pins.firstWhere((p) => p.id == _selectedPinId);
    final session = ref.read(sessionProvider);
    final me = session.profile;
    if (me == null || pin.authorId != me.id) return; // only own pins

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141B26),
        title: const Text(
          'Remove this pin?',
          style: TextStyle(color: Color(0xFFFBF8F4)),
        ),
        content: const Text(
          'It will disappear from both maps.',
          style: TextStyle(color: Color(0x99F5EFE6)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await BodyMapRepository.deletePin(pinId: pin.id);
      setState(() => _selectedPinId = null);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete: $e')),
      );
    }
  }

  Color _colorFor(String authorId, String myId) =>
      authorId == myId ? _meColor : _themColor;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final me = session.profile;
    final myId = me?.id;

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F16),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : _error != null
                      ? _CenterMessage(
                          icon: Icons.lock_outline,
                          text: _error!,
                          actionLabel: 'Try again',
                          onAction: _load,
                        )
                      : _buildCanvas(myId),
            ),
            _buildLegend(myId),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Color(0x80F5EFE6)),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Body Map',
                  style: TextStyle(
                    color: Color(0xFFFBF8F4),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Tap to drop a pin · long-press to delete',
                  style: TextStyle(fontSize: 11, color: Color(0x66F5EFE6)),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Color(0x80F5EFE6), size: 20),
            onPressed: _load,
            tooltip: 'Refresh',
          ),
        ],
      ),
    );
  }

  Widget _buildCanvas(String? myId) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            final tapped = _pinHit(details.localPosition, size, myId);
            if (tapped != null) {
              setState(() {
                _selectedPinId =
                    _selectedPinId == tapped.id ? null : tapped.id;
              });
            } else {
              _addPinAt(details.localPosition, size);
            }
          },
          onLongPressStart: (details) {
            final tapped = _pinHit(details.localPosition, size, myId);
            if (tapped != null &&
                myId != null &&
                tapped.authorId == myId) {
              setState(() => _selectedPinId = tapped.id);
              _deleteSelected();
            }
          },
          child: Stack(
            children: [
              CustomPaint(
                size: Size.infinite,
                painter: BodySilhouettePainter(),
              ),
              ..._pins.map((pin) => _buildPinOverlay(pin, size, myId)),
            ],
          ),
        );
      },
    );
  }

  BodyMapPin? _pinHit(Offset local, Size size, String? myId) {
    BodyMapPin? closest;
    double closestDist = 32; // touch target radius
    for (final pin in _pins) {
      final pos = Offset(pin.x * size.width, pin.y * size.height);
      final d = (pos - local).distance;
      if (d < closestDist) {
        closestDist = d;
        closest = pin;
      }
    }
    return closest;
  }

  Widget _buildPinOverlay(BodyMapPin pin, Size size, String? myId) {
    final isMine = myId != null && pin.authorId == myId;
    final color = _colorFor(pin.authorId, myId ?? '');
    final isSelected = pin.id == _selectedPinId;
    final pos = Offset(pin.x * size.width, pin.y * size.height);

    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: isSelected ? 22 : 16,
              height: isSelected ? 22 : 16,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.45),
                    blurRadius: isSelected ? 16 : 10,
                    spreadRadius: isSelected ? 2 : 0,
                  ),
                ],
                border: Border.all(
                  color: const Color(0xFF0B0F16),
                  width: 2,
                ),
              ),
            ),
            if (isSelected) ...[
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: size.width * 0.7),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF141B26),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: color.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        isMine ? 'You' : 'Them',
                        style: TextStyle(
                          color: color,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        pin.note,
                        style: const TextStyle(
                          color: Color(0xFFFBF8F4),
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLegend(String? myId) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _legendDot(_meColor, 'You'),
          const SizedBox(width: 24),
          _legendDot(_themColor, 'Them'),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(color: Color(0x99F5EFE6), fontSize: 12),
        ),
      ],
    );
  }
}

class _PinNoteDialog extends StatefulWidget {
  const _PinNoteDialog();

  @override
  State<_PinNoteDialog> createState() => _PinNoteDialogState();
}

class _PinNoteDialogState extends State<_PinNoteDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF141B26),
      title: const Text(
        'Add a note',
        style: TextStyle(color: Color(0xFFFBF8F4), fontSize: 18),
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 1,
        maxLines: 2,
        maxLength: 80,
        style: const TextStyle(color: Color(0xFFFBF8F4)),
        decoration: const InputDecoration(
          hintText: 'e.g. here, slowly…',
        ),
        onSubmitted: (_) => Navigator.pop(context, _controller.text.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Drop pin'),
        ),
      ],
    );
  }
}

class _CenterMessage extends StatelessWidget {
  const _CenterMessage({
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });
  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: const Color(0x80F5EFE6)),
            const SizedBox(height: 16),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0x99F5EFE6), height: 1.5),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
