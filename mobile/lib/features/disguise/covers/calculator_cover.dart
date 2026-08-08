import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/features/disguise/cover_gate.dart';

/// A working calculator that is also the front door.
///
/// It has to actually calculate. A disguise that falls apart the moment someone
/// presses a button is worse than none — it advertises that there is something
/// to hide. Arithmetic, the display, and the key feel are all real.
///
/// The hidden trigger is a **long-press on `=` while the display reads `0` with
/// no pending operation** — a normal ~500ms InkWell long-press, not a timed
/// hold.
/// Chosen deliberately: pressing `=` with nothing entered is something no real
/// user does by accident, it leaves no visible affordance, and it cannot be
/// stumbled into while genuinely using the calculator.
class CalculatorCover extends StatefulWidget {
  const CalculatorCover({super.key, required this.onAuthenticated});

  final VoidCallback onAuthenticated;

  @override
  State<CalculatorCover> createState() => _CalculatorCoverState();
}

class _CalculatorCoverState extends State<CalculatorCover>
    with CoverGate<CalculatorCover> {
  String _display = '0';
  double? _accumulator;
  String? _pendingOp;

  /// True right after an operator or equals, so the next digit starts fresh
  /// instead of appending to the previous result.
  bool _startNewEntry = true;

  @override
  void onCoverUnlocked() => widget.onAuthenticated();

  void _input(String key) {
    HapticFeedback.selectionClick();
    setState(() {
      switch (key) {
        case 'AC':
          _display = '0';
          _accumulator = null;
          _pendingOp = null;
          _startNewEntry = true;
        case '⌫':
          if (_startNewEntry || _display.length <= 1) {
            _display = '0';
            _startNewEntry = true;
          } else {
            _display = _display.substring(0, _display.length - 1);
          }
        case '+':
        case '−':
        case '×':
        case '÷':
          _accumulator = _resolve();
          _display = _format(_accumulator!);
          _pendingOp = key;
          _startNewEntry = true;
        case '=':
          final value = _resolve();
          _accumulator = null;
          _pendingOp = null;
          _display = _format(value);
          _startNewEntry = true;
        case '.':
          if (_startNewEntry) {
            _display = '0.';
            _startNewEntry = false;
          } else if (!_display.contains('.')) {
            _display = '$_display.';
          }
        case '%':
          _display = _format((double.tryParse(_display) ?? 0) / 100);
          _startNewEntry = true;
        default: // digits
          if (_startNewEntry || _display == '0') {
            _display = key;
            _startNewEntry = false;
          } else if (_display.replaceAll(RegExp(r'[^0-9]'), '').length < 12) {
            _display = '$_display$key';
          }
      }
    });
  }

  /// Applies the pending operator, if any, to the current entry.
  double _resolve() {
    final current = double.tryParse(_display) ?? 0;
    final acc = _accumulator;
    final op = _pendingOp;
    if (acc == null || op == null) return current;
    return switch (op) {
      '+' => acc + current,
      '−' => acc - current,
      '×' => acc * current,
      // Divide-by-zero shows 0 rather than `Infinity`, which would look broken.
      '÷' => current == 0 ? 0 : acc / current,
      _ => current,
    };
  }

  static String _format(double v) {
    if (v.isNaN || v.isInfinite) return '0';
    if (v == v.roundToDouble() && v.abs() < 1e12) {
      return v.toInt().toString();
    }
    return v
        .toStringAsFixed(6)
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');
  }

  /// The way in — see the class doc for why this gesture.
  void _onEqualsLongPress() {
    if (_display == '0' && _accumulator == null) {
      runEntryGate();
    }
  }

  @override
  Widget build(BuildContext context) {
    const keys = [
      ['AC', '⌫', '%', '÷'],
      ['7', '8', '9', '×'],
      ['4', '5', '6', '−'],
      ['1', '2', '3', '+'],
      ['0', '.', '='],
    ];

    return Scaffold(
      backgroundColor: const Color(0xFFF1F3F4),
      body: SafeArea(
        child: Column(
          children: [
            // Display
            Expanded(
              flex: 2,
              child: Container(
                width: double.infinity,
                alignment: Alignment.bottomRight,
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.bottomRight,
                  child: Text(
                    _display,
                    style: const TextStyle(
                      fontSize: 64,
                      fontWeight: FontWeight.w300,
                      color: Color(0xFF202124),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 5,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    for (final row in keys)
                      Expanded(
                        child: Row(
                          children: [
                            for (final k in row)
                              Expanded(
                                flex: k == '0' ? 2 : 1,
                                child: _Key(
                                  label: k,
                                  onTap: () => _input(k),
                                  onLongPress:
                                      k == '=' ? _onEqualsLongPress : null,
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.label, required this.onTap, this.onLongPress});

  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  bool get _isOperator => '÷×−+='.contains(label);
  bool get _isFunction => label == 'AC' || label == '⌫' || label == '%';

  @override
  Widget build(BuildContext context) {
    final bg = label == '='
        ? const Color(0xFF1A73E8)
        : _isOperator
            ? const Color(0xFFE8F0FE)
            : _isFunction
                ? const Color(0xFFE0E3E7)
                : Colors.white;
    final fg = label == '='
        ? Colors.white
        : _isOperator
            ? const Color(0xFF1A73E8)
            : const Color(0xFF202124);

    return Padding(
      padding: const EdgeInsets.all(5),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          // A long-press that does nothing on every other key, so the one that
          // matters is indistinguishable from the rest.
          onLongPress: onLongPress ?? onTap,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w400,
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
