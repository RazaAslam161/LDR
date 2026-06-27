import 'dart:math';

import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

enum ReactionGesture {
  palmFlat, // flat open hand — pampering, stroking
  pinch, // thumb + index close together
  squeeze, // closed fist — grabbing
  point, // single finger extended — poking, tracing
  unknown, // fallback
}

class ReactionGestureService {
  static final PoseDetector _detector = PoseDetector(
    options: PoseDetectorOptions(
      mode: PoseDetectionMode.single,
    ),
  );

  /// Analyse a single image file and return the detected gesture.
  /// Never throws — returns [ReactionGesture.unknown] on any error.
  static Future<ReactionGesture> detectGesture(String imagePath) async {
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final poses = await _detector.processImage(inputImage);
      if (poses.isEmpty) return ReactionGesture.unknown;

      final pose = poses.first;
      final landmarks = pose.landmarks;

      final leftWrist = landmarks[PoseLandmarkType.leftWrist];
      final rightWrist = landmarks[PoseLandmarkType.rightWrist];
      final leftIndex = landmarks[PoseLandmarkType.leftIndex];
      final rightIndex = landmarks[PoseLandmarkType.rightIndex];
      final leftThumb = landmarks[PoseLandmarkType.leftThumb];
      final rightThumb = landmarks[PoseLandmarkType.rightThumb];
      final leftPinky = landmarks[PoseLandmarkType.leftPinky];
      final rightPinky = landmarks[PoseLandmarkType.rightPinky];

      // Use whichever hand is more visible (higher in-frame likelihood).
      final wrist = (leftWrist?.likelihood ?? 0) > (rightWrist?.likelihood ?? 0)
          ? leftWrist
          : rightWrist;
      final index = (leftIndex?.likelihood ?? 0) > (rightIndex?.likelihood ?? 0)
          ? leftIndex
          : rightIndex;
      final thumb = (leftThumb?.likelihood ?? 0) > (rightThumb?.likelihood ?? 0)
          ? leftThumb
          : rightThumb;
      final pinky = (leftPinky?.likelihood ?? 0) > (rightPinky?.likelihood ?? 0)
          ? leftPinky
          : rightPinky;

      if (wrist == null || index == null) return ReactionGesture.unknown;

      // PINCH: thumb and index very close together.
      if (thumb != null) {
        final dx = (thumb.x - index.x).abs();
        final dy = (thumb.y - index.y).abs();
        if (sqrt(dx * dx + dy * dy) < 40) return ReactionGesture.pinch;
      }

      // POINT: index far from wrist, pinky close to wrist.
      if (pinky != null) {
        final indexDist = sqrt(
          pow(index.x - wrist.x, 2) + pow(index.y - wrist.y, 2),
        );
        final pinkyDist = sqrt(
          pow(pinky.x - wrist.x, 2) + pow(pinky.y - wrist.y, 2),
        );
        if (indexDist > pinkyDist * 1.5) return ReactionGesture.point;
      }

      // PALM FLAT: index and pinky spread wide.
      if (pinky != null) {
        final spread = sqrt(
          pow(index.x - pinky.x, 2) + pow(index.y - pinky.y, 2),
        );
        if (spread > 60) return ReactionGesture.palmFlat;
      }

      // SQUEEZE: all fingers close to wrist (fist).
      return ReactionGesture.squeeze;
    } catch (_) {
      return ReactionGesture.unknown;
    }
  }

  static void dispose() => _detector.close();
}
