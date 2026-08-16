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

// The Maps key has to sit in the merged manifest in plaintext — the Maps SDK
// reads it from there and from nowhere else, so it cannot hide behind an edge
// function the way the Mapbox token does. Keeping it out of the tracked
// manifest at least stops the next rotation from landing in git history again.
val mapsProperties = Properties().apply {
    val f = rootProject.file("maps.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val mapsApiKey = mapsProperties.getProperty("mapsApiKey") ?: run {
    logger.warn("=========================================================")
    logger.warn(" NO android/maps.properties - Google Maps will NOT load.")
    logger.warn(" Add mapsApiKey=<key>. Touch Map ships blank without it.")
    logger.warn("=========================================================")
    // Not an empty string: the SDK logs an explicit authorisation failure for
    // a key it cannot parse, where an empty one just draws a grey rectangle.
    "MISSING_MAPS_API_KEY"
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
        // Resolves to 24 (Android 7.0) from the Flutter SDK - verified in the
        // merged manifest. Supabase Realtime, FCM and Firebase all need >= 23.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["mapsApiKey"] = mapsApiKey
    }

    buildFeatures {
        // For DISGUISE_ENABLED below. Off by default since AGP 8.
        buildConfig = true
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

    // Two channels, and the difference between them is a Play policy question
    // rather than a cosmetic one. sideload is today's app, unchanged. play
    // strips the launcher disguise (src/play/AndroidManifest.xml), will not
    // fall back to the debug key, and runs R8.
    //
    // Signing hangs off the flavour, not the build type, because a build type
    // cannot see which channel it is building. A build type that DID set one
    // would win over both of these.
    flavorDimensions += "channel"
    productFlavors {
        create("sideload") {
            dimension = "channel"
            isDefault = true
            buildConfigField("boolean", "DISGUISE_ENABLED", "true")
            // Installs as Miles, under its own name and icon, and offers the
            // covers on first open. An identity nobody chose is a worse default
            // even where no policy forbids it: the owner picks the cover,
            // having been shown what it does. The play channel no longer offers
            // them at all.
            buildConfigField("boolean", "PLAIN_DEFAULT", "true")
            // Only this channel may install its own APK. Kept as its own flag
            // rather than inferred from the two above, both of which have
            // legitimately changed meaning more than once — a self-updater
            // gated on DISGUISE_ENABLED would have started offering downloads
            // inside a Play build during the window where that flag was true on
            // both channels.
            buildConfigField("boolean", "SELF_UPDATE", "true")
            // The debug keystore's password is the literally-documented string
            // "android" on every machine on earth, and anything signed with it
            // can be re-signed by anyone. Falling back is tolerable only
            // because this channel never goes near Play and because the warning
            // is impossible to miss.
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("=========================================================")
                logger.warn(" NO android/key.properties - signing sideload with DEBUG.")
                logger.warn(" This APK CANNOT be uploaded to Google Play. Sideload only.")
                logger.warn("=========================================================")
                signingConfigs.getByName("debug")
            }
        }
        create("play") {
            dimension = "channel"
            // Covers ship here, and the listing DISCLOSES them (owner's call:
            // the feature is the point of the app for the people who need it).
            // Play's Deceptive Behavior policy protects the person holding the
            // phone — a cover they chose, having been told what it does and how
            // to get back, deceives nobody. What it does forbid is a fresh
            // install quietly offering nine invented identities before the user
            // has any idea what the app is, which is what the first-run picker
            // used to do.
            //
            // Shipping this channel therefore REQUIRES all of, and a change to
            // any one of them is a policy change, not a UI tweak:
            //   1. no unprompted cover offer on first run (app_shell)
            //   2. a confirmation that names the consequence and the way back,
            //      before any cover is applied (disguise_picker_screen)
            //   3. a visible way out on every cover screen
            //   4. the feature described in the store listing, with the picker
            //      in at least one screenshot
            //   5. the unlock gesture + a test account in Console > App access
            // Items 4 and 5 are Console-side; see PLAY-READINESS-AUDIT.md.
            buildConfigField("boolean", "DISGUISE_ENABLED", "true")
            // Installs as Miles, under its own name and icon, and stays that
            // way until the owner asks otherwise.
            buildConfigField("boolean", "PLAIN_DEFAULT", "true")
            // Never. An app that downloads and installs its own APK is a Device
            // and Network Abuse strike, and the permission plus FileProvider
            // that back it are declared only in src/sideload.
            buildConfigField("boolean", "SELF_UPDATE", "false")
            // No fallback: the taskGraph check below stops the build instead of
            // handing back an artifact Play will reject.
            if (hasReleaseKey) signingConfig = signingConfigs.getByName("release")
        }
    }

    buildTypes {
        release {
            // R8 (minify + resource shrink) is OFF for the directly-shared
            // universal APK: it can strip reflection/JNI paths in WebRTC and
            // ML Kit that only fail on a real device, and that cannot be
            // verified from a build machine. The play channel turns both on in
            // the androidComponents block below, because an AAB has to be
            // shrunk and is going through review anyway.
            isMinifyEnabled = false
            isShrinkResources = false
            // Wired while minification is off, because R8 reads these only when
            // isMinifyEnabled is true. Without them here, flipping that flag
            // silently ran R8 on its defaults alone - which strips exactly the
            // reflection/JNI entry points proguard-rules.pro exists to keep.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
    // sideload: one universal APK, every ABI, so it installs on every Android
    // device. play: an AAB, which Play splits per device itself.
}

androidComponents {
    // isMinifyEnabled is a build-type property in the DSL and there is only one
    // release build type, so the per-channel difference has to be made here.
    beforeVariants(
        selector().withFlavor("channel", "play").withBuildType("release"),
    ) { variant ->
        variant.isMinifyEnabled = true
        variant.shrinkResources = true
    }
}

// Play rejects debug-signed uploads outright, so the play channel must stop
// rather than produce one. Checked off the task graph rather than at
// configuration time: an absent key.properties is the normal, correct state
// for a sideload build, and configuring it as an error would break that.
// A dependsOn edge cannot express this either - every pre<Variant>Build hangs
// off the shared preBuild, so gating there fails sideload too, and gating on
// assemblePlayRelease only fires after R8 has already run.
gradle.taskGraph.whenReady {
    val buildingPlay = allTasks.any {
        it.project == project &&
            (it.name == "packagePlayRelease" || it.name == "packagePlayReleaseBundle")
    }
    if (buildingPlay && !hasReleaseKey) {
        throw GradleException(
            "android/key.properties is missing, so the play channel has no " +
                "upload key. Create the keystore and key.properties, or " +
                "build --flavor sideload.",
        )
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
