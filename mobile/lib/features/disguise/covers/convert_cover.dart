import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/features/disguise/cover_gate.dart';
import 'package:miles/features/disguise/covers/cover_theme.dart';
import 'package:miles/features/disguise/disguise_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A unit and currency converter.
///
/// Chosen as a cover because it is output-only. There is no list, no history
/// and no detail screen: someone who taps the icon sees metres converted to
/// feet and has already seen everything the app contains. Unlike the notepad it
/// can never accumulate content that looks like it belongs to a person.
///
/// The rates are a static table with the date printed under them, and no
/// network call is made. A converter that phones a third party is a request in
/// the packet log of an app that only has to look like a converter to a person.
///
/// **The way in: hold the swap control while both sides are on the same unit
/// and the amount is empty.** Tapping swap is the only thing that control is
/// for, and it is a tap. Same-unit + empty + hold is three coincidences at
/// once, and it is a state the app permits — converting metres to metres is
/// legal, just pointless — so nothing on screen looks disabled or special.
class ConvertCover extends StatefulWidget {
  const ConvertCover({required this.onAuthenticated, super.key});

  final VoidCallback onAuthenticated;

  @override
  State<ConvertCover> createState() => _ConvertCoverState();
}

class _ConvertCoverState extends State<ConvertCover>
    with CoverGate<ConvertCover> {
  static const _prefsKey = 'convert_last_pair';

  final _input = TextEditingController();
  late _Category _category = _categories.first;
  late _Unit _from = _category.defaultFrom;
  late _Unit _to = _category.defaultTo;

  @override
  void initState() {
    super.initState();
    _input.addListener(_onTyped);
    _restore();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  void onCoverUnlocked() => widget.onAuthenticated();

  /// Reopening where you left off is what a tool you actually use does.
  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final parts = (prefs.getString(_prefsKey) ?? '').split('|');
    if (parts.length != 3 || !mounted) return;
    final category = _categories.firstWhere(
      (c) => c.name == parts[0],
      orElse: () => _categories.first,
    );
    setState(() {
      _category = category;
      _from = category.unitFor(parts[1]) ?? category.defaultFrom;
      _to = category.unitFor(parts[2]) ?? category.defaultTo;
    });
  }

  Future<void> _remember() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey, '${_category.name}|${_from.symbol}|${_to.symbol}',);
  }

  void _onTyped() => setState(() {});

  void _pickCategory(_Category c) {
    setState(() {
      _category = c;
      _from = c.defaultFrom;
      _to = c.defaultTo;
    });
    unawaited(_remember());
  }

  void _swap() {
    HapticFeedback.selectionClick();
    setState(() {
      final held = _from;
      _from = _to;
      _to = held;
    });
    unawaited(_remember());
  }

  /// The door — see the class doc for why this state and not another.
  void _onSwapHold() {
    if (_from.symbol == _to.symbol && _input.text.trim().isEmpty) {
      runEntryGate();
    }
  }

  Future<void> _pickUnit({required bool forSource}) async {
    final chosen = await showModalBottomSheet<_Unit>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _UnitSheet(
        category: _category,
        selected: forSource ? _from : _to,
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      if (forSource) {
        _from = chosen;
      } else {
        _to = chosen;
      }
    });
    await _remember();
  }

  double get _amount => double.tryParse(_input.text.trim()) ?? 0;

  String get _result {
    final base = _amount * _from.factor + _from.offset;
    final out = (base - _to.offset) / _to.factor;
    if (!out.isFinite) return '0';
    final abs = out.abs();
    // Six significant figures either way: a converter that prints 12 decimals
    // for a kilometre looks like a debugging tool, and one that rounds a
    // milligram to zero looks broken.
    if (abs != 0 && (abs >= 1e9 || abs < 1e-4)) {
      return out.toStringAsExponential(4);
    }
    final decimals = abs >= 1000 ? 2 : (abs >= 1 ? 4 : 6);
    final text = out.toStringAsFixed(decimals);
    return text.contains('.')
        ? text.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')
        : text;
  }

  @override
  Widget build(BuildContext context) {
    final theme = coverTheme(
      primary: const Color(0xFF0F766E),
      surface: const Color(0xFFF7F8F8),
    );
    return Theme(
      data: theme,
      child: Scaffold(
        appBar: AppBar(
          title: CoverAboutTap(
            onTap: () => showCoverAbout(context,
                cover: DisguiseCover.convert,
                onOpen: runEntryGate,
                theme: theme,),
            child: const Text('Convert'),
          ),
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 48,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _categories.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, i) {
                    final c = _categories[i];
                    return Center(
                      child: ChoiceChip(
                        label: Text(c.name),
                        selected: c.name == _category.name,
                        onSelected: (_) => _pickCategory(c),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _Field(
                  unit: _from,
                  onUnitTap: () => _pickUnit(forSource: true),
                  child: TextField(
                    controller: _input,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
                    ],
                    style: const TextStyle(
                        fontSize: 34, fontWeight: FontWeight.w300,),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      hintText: '0',
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: IconButton.filledTonal(
                    onPressed: _swap,
                    // A long-press on the one control that has one. It does
                    // nothing at all unless the app is in the resting state
                    // described on the class.
                    onLongPress: _onSwapHold,
                    icon: const Icon(Icons.swap_vert_rounded),
                    tooltip: 'Swap',
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _Field(
                  unit: _to,
                  onUnitTap: () => _pickUnit(forSource: false),
                  child: Text(
                    _result,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w300,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              if (_category.ratesNote != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  child: Text(
                    _category.ratesNote!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.unit,
    required this.onUnitTap,
    required this.child,
  });

  final _Unit unit;
  final VoidCallback onUnitTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Expanded(child: child),
          TextButton(
            onPressed: onUnitTap,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(unit.symbol),
                const Icon(Icons.arrow_drop_down, size: 20),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UnitSheet extends StatefulWidget {
  const _UnitSheet({required this.category, required this.selected});

  final _Category category;
  final _Unit selected;

  @override
  State<_UnitSheet> createState() => _UnitSheetState();
}

class _UnitSheetState extends State<_UnitSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final units = widget.category.units
        .where((u) =>
            q.isEmpty ||
            u.name.toLowerCase().contains(q) ||
            u.symbol.toLowerCase().contains(q),)
        .toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                decoration: const InputDecoration(
                  hintText: 'Search units',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: units.length,
                itemBuilder: (context, i) => ListTile(
                  title: Text(units[i].name),
                  trailing: Text(units[i].symbol),
                  selected: units[i].symbol == widget.selected.symbol,
                  onTap: () => Navigator.pop(context, units[i]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One unit, expressed against its category's base unit as
/// `base = value * factor + offset`. The offset exists for temperature and is
/// zero everywhere else.
class _Unit {
  const _Unit(this.name, this.symbol, this.factor, [this.offset = 0]);

  final String name;
  final String symbol;
  final double factor;
  final double offset;
}

class _Category {
  const _Category(
    this.name,
    this.units, {
    required this.defaultFromIndex,
    required this.defaultToIndex,
    this.ratesNote,
  });

  final String name;
  final List<_Unit> units;

  /// The pair the category opens on. Not the first two units: a converter that
  /// starts on millimetres-to-centimetres is one nobody would have installed.
  final int defaultFromIndex;
  final int defaultToIndex;

  /// Printed under the result where the numbers are not laws of physics.
  final String? ratesNote;

  _Unit get defaultFrom => units[defaultFromIndex];
  _Unit get defaultTo => units[defaultToIndex];

  _Unit? unitFor(String symbol) {
    for (final u in units) {
      if (u.symbol == symbol) return u;
    }
    return null;
  }
}

const _categories = <_Category>[
  _Category('Length', [
    _Unit('Millimetre', 'mm', 0.001),
    _Unit('Centimetre', 'cm', 0.01),
    _Unit('Metre', 'm', 1),
    _Unit('Kilometre', 'km', 1000),
    _Unit('Inch', 'in', 0.0254),
    _Unit('Foot', 'ft', 0.3048),
    _Unit('Yard', 'yd', 0.9144),
    _Unit('Mile', 'mi', 1609.344),
    _Unit('Nautical mile', 'nmi', 1852),
  ], defaultFromIndex: 2, defaultToIndex: 5),
  _Category('Mass', [
    _Unit('Milligram', 'mg', 0.000001),
    _Unit('Gram', 'g', 0.001),
    _Unit('Kilogram', 'kg', 1),
    _Unit('Tonne', 't', 1000),
    _Unit('Ounce', 'oz', 0.028349523125),
    _Unit('Pound', 'lb', 0.45359237),
    _Unit('Stone', 'st', 6.35029318),
  ], defaultFromIndex: 2, defaultToIndex: 5),
  _Category('Temperature', [
    _Unit('Celsius', '°C', 1),
    _Unit('Fahrenheit', '°F', 0.5555555555555556, -17.77777777777778),
    _Unit('Kelvin', 'K', 1, -273.15),
  ], defaultFromIndex: 0, defaultToIndex: 1),
  _Category('Volume', [
    _Unit('Millilitre', 'ml', 0.001),
    _Unit('Litre', 'L', 1),
    _Unit('Cubic metre', 'm³', 1000),
    _Unit('Teaspoon', 'tsp', 0.00492892159375),
    _Unit('Tablespoon', 'tbsp', 0.01478676478125),
    _Unit('Cup', 'cup', 0.2365882365),
    _Unit('Pint', 'pt', 0.473176473),
    _Unit('Gallon', 'gal', 3.785411784),
    _Unit('Fluid ounce', 'fl oz', 0.0295735295625),
  ], defaultFromIndex: 1, defaultToIndex: 7),
  _Category('Data', [
    _Unit('Byte', 'B', 1),
    _Unit('Kilobyte', 'kB', 1000),
    _Unit('Megabyte', 'MB', 1000000),
    _Unit('Gigabyte', 'GB', 1000000000),
    _Unit('Terabyte', 'TB', 1000000000000),
    _Unit('Kibibyte', 'KiB', 1024),
    _Unit('Mebibyte', 'MiB', 1048576),
    _Unit('Gibibyte', 'GiB', 1073741824),
  ], defaultFromIndex: 2, defaultToIndex: 6),
  _Category('Speed', [
    _Unit('Metres per second', 'm/s', 1),
    _Unit('Kilometres per hour', 'km/h', 0.2777777777777778),
    _Unit('Miles per hour', 'mph', 0.44704),
    _Unit('Knot', 'kn', 0.5144444444444445),
    _Unit('Feet per second', 'ft/s', 0.3048),
  ], defaultFromIndex: 1, defaultToIndex: 2),
  _Category(
    'Currency',
    [
      _Unit('US dollar', 'USD', 1),
      _Unit('Euro', 'EUR', 1.08),
      _Unit('Pound sterling', 'GBP', 1.27),
      _Unit('Japanese yen', 'JPY', 0.0064),
      _Unit('Indian rupee', 'INR', 0.012),
      _Unit('Pakistani rupee', 'PKR', 0.0036),
      _Unit('Australian dollar', 'AUD', 0.66),
      _Unit('Canadian dollar', 'CAD', 0.73),
      _Unit('Swiss franc', 'CHF', 1.12),
      _Unit('Chinese yuan', 'CNY', 0.138),
      _Unit('UAE dirham', 'AED', 0.272),
    ],
    defaultFromIndex: 0,
    defaultToIndex: 1,
    // Stated plainly, because an offline table is what an offline converter
    // has. The alternative is a network call this app will not make.
    ratesNote: 'Reference rates, offline. Last updated 1 August 2026.',
  ),
];
