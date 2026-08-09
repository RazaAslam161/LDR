# R8 keep rules for the release build.
#
# R8 shrinks and obfuscates. Anything reached by reflection or JNI is invisible
# to it and gets stripped or renamed unless kept here. These plugins all do
# one or the other, so each is a class of runtime crash R8 would otherwise
# introduce silently — invisible to unit tests, only reproducible on-device.

# Flutter engine and embedding (reflection from native).
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.**

# ML Kit — models and native detectors resolve their Java entry points by name.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
-dontwarn com.google.mlkit.**

# WebRTC (flutter_webrtc / libjingle) — JNI both directions.
-keep class org.webrtc.** { *; }
-dontwarn org.webrtc.**

# Firebase Cloud Messaging.
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**

# flutter_local_notifications serializes/deserializes via Gson-style reflection.
-keep class com.dexterous.** { *; }

# Play Core: Flutter's embedding references it for deferred components even when
# unused. Not bundled here, so silence the reference rather than fail the build.
-dontwarn com.google.android.play.core.**

# Keep annotations and generic signatures other keeps rely on.
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod
