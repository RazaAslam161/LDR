import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing lives outside the repo. android/.gitignore already covers
// key.properties and *.keystore, so the signing material never reaches git.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseKey = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "com.miles.miles"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications 22.x (uses java.time APIs).
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.miles.miles"
        // Resolves to 24 (Android 7.0) from the Flutter SDK - verified in the
        // merged manifest. Supabase Realtime, FCM and Firebase all need >= 23.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Sign with every scheme the platform accepts. minSdk resolves to 24,
        // so AGP legitimately drops the v1 (JAR) signature - v2 covers API 24+
        // and v3 adds key rotation. Asking for all three costs nothing and
        // means the APK stays installable if minSdk is ever lowered.
        getByName("debug") {
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
        }
        if (hasReleaseKey) {
            create("release") {
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // The debug keystore's password is the literally-documented string
            // "android" on every machine on earth. Play rejects APKs signed
            // with it, and anything signed with it can be re-signed by anyone.
            // Falling back is only tolerable because it is impossible to miss.
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("=========================================================")
                logger.warn(" NO android/key.properties - signing release with DEBUG.")
                logger.warn(" This APK CANNOT be uploaded to Google Play. Sideload only.")
                logger.warn("=========================================================")
                signingConfigs.getByName("debug")
            }
            // R8 (minify + resource shrink) is OFF for the directly-shared
            // universal APK: it can strip reflection/JNI paths in WebRTC and
            // ML Kit that only fail on a real device, and that cannot be
            // verified from a build machine. proguard-rules.pro is written and
            // ready; enable this once the build has been tapped through on a
            // phone (calls + touch-map especially).
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
    // One universal APK, every ABI, so it installs on every Android device.
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Backport of java.time / java.util APIs for flutter_local_notifications 22.x.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

// (No version pins needed — AGP 8.13 + Kotlin 2.2.0 supports the latest
// transitive deps pulled by the plugin chain.)
