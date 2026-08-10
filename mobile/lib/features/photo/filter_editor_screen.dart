import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:miles/core/theme.dart';

/// A preset beauty/enhance filter applied to a photo after capture.
class _Preset {
  const _Preset(this.key, this.label);
  final String key;
  final String label;
}

const List<_Preset> _presets = [
  _Preset('none', 'Original'),
  _Preset('smooth', 'Smooth'),
  _Preset('glow', 'Glow'),
  _Preset('warm', 'Warm'),
  _Preset('cool', 'Cool'),
  _Preset('bw', 'B&W'),
  _Preset('vintage', 'Vintage'),
];

class _FilterArgs {
  const _FilterArgs(this.bytes, this.preset, this.maxWidth, this.quality);
  final Uint8List bytes;
  final String preset;
  final int maxWidth; // 0 = keep size
  final int quality;
}

/// Runs in a background isolate (via compute) so filtering never janks the UI.
Uint8List _processBytes(_FilterArgs a) {
  var image = img.decodeImage(a.bytes);
  if (image == null) return a.bytes;
  if (a.maxWidth > 0 && image.width > a.maxWidth) {
    image = img.copyResize(image, width: a.maxWidth);
  }
  switch (a.preset) {
    case 'smooth': // soft skin — blend a gentle blur + lift
      image = img.gaussianBlur(image, radius: 2);
      image = img.colorOffset(image, red: 10, green: 10, blue: 10);
    case 'glow': // brighter, dreamier bloom
      image = img.gaussianBlur(image, radius: 3);
      image = img.colorOffset(image, red: 24, green: 20, blue: 16);
    case 'warm':
      image = img.colorOffset(image, red: 24, green: 8, blue: -14);
    case 'cool':
      image = img.colorOffset(image, red: -12, blue: 22);
    case 'bw':
      image = img.grayscale(image);
    case 'vintage':
      image = img.sepia(image);
      image = img.vignette(image);
    default:
      break; // 'none'
  }
  return img.encodeJpg(image, quality: a.quality);
}

/// Full-screen editor: pick a beauty preset, preview live, confirm.
/// Returns the processed [File], or null on cancel.
class FilterEditorScreen extends StatefulWidget {
  const FilterEditorScreen({required this.file, super.key});
  final File file;

  static Future<File?> edit(BuildContext context, File file) {
    return Navigator.of(context).push<File>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => FilterEditorScreen(file: file),
      ),
    );
  }

  @override
  State<FilterEditorScreen> createState() => _FilterEditorScreenState();
}

class _FilterEditorScreenState extends State<FilterEditorScreen> {
  Uint8List? _original;
  Uint8List? _preview;
  String _preset = 'none';
  bool _busy = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _original = await widget.file.readAsBytes();
    if (mounted) setState(() => _preview = _original);
  }

  Future<void> _select(String preset) async {
    if (_original == null || _busy) return;
    setState(() {
      _preset = preset;
      _busy = true;
    });
    final out = await compute(
      _processBytes,
      _FilterArgs(_original!, preset, 700, 85),
    );
    if (mounted) {
      setState(() {
        _preview = out;
        _busy = false;
      });
    }
  }

  Future<void> _confirm() async {
    if (_original == null) return;
    if (_preset == 'none') {
      if (mounted) Navigator.of(context).pop(widget.file);
      return;
    }
    setState(() => _saving = true);
    final out = await compute(
      _processBytes,
      _FilterArgs(_original!, _preset, 0, 88),
    );
    final dest = File('${widget.file.path}.f.jpg');
    await dest.writeAsBytes(out);
    if (mounted) Navigator.of(context).pop(dest);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MilesColors.night,
      appBar: AppBar(
        title: const Text('Enhance'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.check, color: MilesColors.sage),
              onPressed: _confirm,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _preview == null
                  ? const CircularProgressIndicator()
                  : Stack(
                      alignment: Alignment.center,
                      children: [
                        Image.memory(_preview!,
                            fit: BoxFit.contain, gaplessPlayback: true,),
                        if (_busy)
                          const CircularProgressIndicator(strokeWidth: 2),
                      ],
                    ),
            ),
          ),
          SizedBox(
            height: 92,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              itemCount: _presets.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final p = _presets[i];
                final on = p.key == _preset;
                return GestureDetector(
                  onTap: () => _select(p.key),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: on
                          ? MilesColors.ember.withValues(alpha: 0.22)
                          : MilesColors.surface1,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: on ? MilesColors.ember : Colors.transparent,
                      ),
                    ),
                    child: Text(
                      p.label,
                      style: TextStyle(
                        color: on ? MilesColors.cream50 : MilesColors.taupe,
                        fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                      ),
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
}
