import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/photo/filter_editor_screen.dart';
import 'package:miles/main.dart' show MilesApp;

/// Crop shape for [PhotoPickerService.pick].
enum PhotoShape { square, free }

/// One item out of a multi-pick, tagged. Photos and videos go to different
/// buckets and become different message kinds, and the picker hands them back
/// interleaved in whatever order the user tapped them.
typedef PickedMedia = ({File file, bool isVideo});

/// Picking photos and videos. Two paths on purpose: [pick] crops and compresses
/// to a ≤1200px JPEG for the surfaces that need a bounded, framed image (avatar,
/// check-in snap, chat background), while [pickMedia] hands chat what the user
/// actually picked, untouched.
class PhotoPickerService {
  PhotoPickerService._();

  static final ImagePicker _picker = ImagePicker();

  /// Point the plugin at Android's system Photo Picker.
  ///
  /// image_picker_android defaults useAndroidPhotoPicker to FALSE, and with it
  /// false every gallery entry point fires `Intent.ACTION_GET_CONTENT` — the
  /// document provider. That is the whole of "sending multiple pics and videos
  /// takes me to the phone drive or file manager": browsing folders for your
  /// own photos, with no video thumbnails and no multi-select worth the name.
  /// True fires `PickVisualMedia` instead, which IS the gallery, and which
  /// androidx falls back off gracefully on devices too old to have it.
  ///
  /// Called from each entry point rather than from main(): a picker that opens
  /// the wrong app is not a thing to leave depending on a bootstrap line
  /// somebody may reorder. Assignment is idempotent and the platform instance
  /// is a singleton.
  static void _useSystemGallery() {
    final impl = ImagePickerPlatform.instance;
    if (impl is ImagePickerAndroid) impl.useAndroidPhotoPicker = true;
  }

  /// Returns a cropped + compressed file, or null if the user cancels.
  /// Pass [enhanceContext] to offer the beauty-filter step after cropping.
  static Future<File?> pick({
    required ImageSource source,
    PhotoShape shape = PhotoShape.free,
    BuildContext? enhanceContext,
  }) async {
    _useSystemGallery();
    // Guard the News cover for the WHOLE flow: pickImage, the native crop UI
    // (UCrop), and the enhance step are all system/heavy overlays that bounce
    // the app through inactive/paused. Cleared in finally on every exit path.
    MilesApp.systemOverlayActive = true;
    try {
      return await _pick(source: source, shape: shape, enhanceContext: enhanceContext);
    } finally {
      MilesApp.systemOverlayActive = false;
    }
  }

  static Future<File?> _pick({
    required ImageSource source,
    PhotoShape shape = PhotoShape.free,
    BuildContext? enhanceContext,
  }) async {
    final picked = await _picker.pickImage(
        source: source, maxWidth: 2400, imageQuality: 92,);
    if (picked == null) return null;

    final cropped = await ImageCropper().cropImage(
      sourcePath: picked.path,
      maxWidth: 1200,
      maxHeight: 1200,
      compressQuality: 80,
      aspectRatio: shape == PhotoShape.square
          ? const CropAspectRatio(ratioX: 1, ratioY: 1)
          : null,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Adjust',
          toolbarColor: MilesColors.night,
          toolbarWidgetColor: MilesColors.cream50,
          backgroundColor: MilesColors.night,
          activeControlsWidgetColor: MilesColors.ember,
          lockAspectRatio: shape == PhotoShape.square,
          hideBottomControls: false,
          aspectRatioPresets: shape == PhotoShape.square
              ? const [CropAspectRatioPreset.square]
              : const [
                  CropAspectRatioPreset.original,
                  CropAspectRatioPreset.square,
                  CropAspectRatioPreset.ratio4x3,
                  CropAspectRatioPreset.ratio16x9,
                ],
        ),
        IOSUiSettings(title: 'Adjust'),
      ],
    );
    if (cropped == null) return null;
    final file = File(cropped.path);
    // Optional beauty/enhance pass.
    if (enhanceContext != null && enhanceContext.mounted) {
      final edited = await FilterEditorScreen.edit(enhanceContext, file);
      return edited ?? file;
    }
    return file;
  }

  /// Photos AND videos in one pick, up to [limit] items, untouched.
  ///
  /// No crop, no enhance, no maxWidth/imageQuality: those re-encode, and the
  /// chat sends what the user picked. The old flow was one item at a time
  /// through a ratio step and a filter step, and picking a dozen holiday
  /// photos meant running it a dozen times.
  static Future<List<PickedMedia>> pickMedia({int limit = 50}) async {
    _useSystemGallery();
    MilesApp.systemOverlayActive = true;
    try {
      final picked = await _picker.pickMultipleMedia(limit: limit);
      // The plugin documents `limit` as advisory — a platform that cannot
      // enforce it ignores it — so the cap is applied here too rather than
      // trusting the gallery to have honoured it.
      return [
        for (final x in picked.take(limit))
          (file: File(x.path), isVideo: isVideoPick(x.path, x.mimeType)),
      ];
    } finally {
      MilesApp.systemOverlayActive = false;
    }
  }

  /// Whether a picked item is a video.
  ///
  /// Get this wrong and the file is uploaded to the photo bucket and inserted
  /// as kind='image', which renders forever as a broken picture — the message
  /// is not recoverable afterwards, so it is worth being deliberate about.
  /// Extension first: image_picker copies into the app cache keeping it, while
  /// mimeType is routinely null on Android.
  @visibleForTesting
  static bool isVideoPick(String path, String? mimeType) {
    const videoExts = {'mp4', 'mov', 'm4v', '3gp', 'webm', 'mkv', 'avi'};
    const imageExts = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif'};
    final dot = path.lastIndexOf('.');
    final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
    if (videoExts.contains(ext)) return true;
    if (imageExts.contains(ext)) return false;
    return (mimeType ?? '').toLowerCase().startsWith('video/');
  }

  /// Pick (or record) a video — no crop. Capped at 5 minutes to bound size.
  static Future<File?> pickVideo({required ImageSource source}) async {
    _useSystemGallery();
    MilesApp.systemOverlayActive = true;
    try {
      final x = await _picker.pickVideo(
        source: source,
        maxDuration: const Duration(minutes: 5),
      );
      return x == null ? null : File(x.path);
    } finally {
      MilesApp.systemOverlayActive = false;
    }
  }

  /// Shows a camera/gallery sheet, then pick + crop (+ optional enhance).
  /// Returns null on cancel.
  static Future<File?> pickFromSheet(
    BuildContext context, {
    PhotoShape shape = PhotoShape.free,
    bool enhance = true,
  }) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: MilesColors.surface1,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined,
                  color: MilesColors.emberSoft,),
              title: const Text('Take a photo',
                  style: TextStyle(color: MilesColors.cream50),),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined,
                  color: MilesColors.emberSoft,),
              title: const Text('Choose from gallery',
                  style: TextStyle(color: MilesColors.cream50),),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !context.mounted) return null;
    return pick(
      source: source,
      shape: shape,
      enhanceContext: enhance ? context : null,
    );
  }
}
