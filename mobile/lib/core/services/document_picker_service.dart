import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:miles/main.dart' show MilesApp;

/// One item out of a document pick. The name and the size come from the
/// provider, not from the path: Android hands back a cached copy under a name
/// of its own, and the size is what decides whether the upload is worth
/// starting.
typedef PickedDocument = ({File file, String name, int size});

/// Picking documents — a DIFFERENT intent from the photo gallery, which is why
/// it is a different service and a different button.
///
/// The gallery picker (PhotoPickerService) fires PickVisualMedia, which offers
/// photos and videos and nothing else. Documents need the storage provider,
/// and asking one intent to do both is how the app ended up in the file
/// manager when the user wanted their camera roll.
class DocumentPickerService {
  DocumentPickerService._();

  /// couple_files' file_size_limit. Checked before the upload starts so the
  /// user is told what happened, instead of watching a bubble fail with a
  /// storage error nobody can read.
  static const maxBytes = 26214400;

  /// The document provider, multi-select, any type.
  static Future<List<PickedDocument>> pick({int limit = 10}) async {
    MilesApp.systemOverlayActive = true;
    try {
      final res = await FilePicker.pickFiles(allowMultiple: true);
      if (res == null) return const [];
      return [
        for (final f in res.files.take(limit))
          if (f.path != null)
            (file: File(f.path!), name: f.name, size: f.size),
      ];
    } finally {
      MilesApp.systemOverlayActive = false;
    }
  }

  /// A size a person reads, for the bubble.
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit]}';
  }
}
