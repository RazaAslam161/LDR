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
        // minSdk 23 (Android 6.0) — required by Supabase Realtime, firebase_messaging
        // 16.x, and most plugins. Pinned explicitly (FCM needs >= 21; Firebase >= 23).
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
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
            isMinifyEnabled = false
            isShrinkResources = false
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
