import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/features/photo/filter_editor_screen.dart';
import 'package:miles/main.dart' show MilesApp;

/// Crop shape for [PhotoPickerService.pick].
enum PhotoShape { square, free }

/// One reusable pick → crop/adjust → compress pipeline for every photo surface
/// (avatar, check-in snap, chat photo). Output is ≤1200px JPEG (~quality 80).
class PhotoPickerService {
  PhotoPickerService._();

  static final ImagePicker _picker = ImagePicker();

  /// Returns a cropped + compressed file, or null if the user cancels.
  /// Pass [enhanceContext] to offer the beauty-filter step after cropping.
  static Future<File?> pick({
    required ImageSource source,
    PhotoShape shape = PhotoShape.free,
    BuildContext? enhanceContext,
  }) async {
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

  /// Pick (or record) a video — no crop. Capped at 5 minutes to bound size.
  static Future<File?> pickVideo({required ImageSource source}) async {
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
