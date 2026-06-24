plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

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
        // minSdk 23 (Android 6.0) — required by Supabase Realtime, firebase_messaging
        // 16.x, and most plugins. Pinned explicitly (FCM needs >= 21; Firebase >= 23).
        minSdk = 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
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
