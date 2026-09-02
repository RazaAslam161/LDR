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
            // ALWAYS the debug key, and never the release one — the opposite of
            // what this used to do, for a reason that cost a shipped release.
            //
            // This was `if (hasReleaseKey) release else debug`. Creating
            // android/key.properties to get a PLAY upload key therefore changed
            // what the SIDELOAD channel was signed with, as a side effect, on
            // the same afternoon. Android refuses to install an APK whose
            // certificate differs from the installed one, so build 45 met every
            // phone in the field with:
            //
            //     App not installed as package conflicts with an existing package
            //
            // and the only way past it is uninstalling — which destroys the
            // device's X25519 seed and, for anyone without an escrow row, their
            // ability to read the couple's history at all. A Play packaging
            // decision must never be able to reach out and orphan the installed
            // base; these are two channels precisely so they can differ.
            //
            // The debug keystore's password is the literally-documented string
            // "android" on every machine on earth, and anything signed with it
            // can be re-signed by anyone. That is tolerable here only because
            // this channel never goes near Play — enforced by the taskGraph
            // check below, not by convention — and it is the price of an
            // installed base that can keep updating.
            //
            // The sideload-to-Play migration is a real, separate event: it needs
            // every user to have an escrow row FIRST, then a deliberate
            // uninstall/reinstall. It is not something a build config should
            // trigger by accident.
            signingConfig = signingConfigs.getByName("debug")

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
            //   3. a way back the owner can FIND on every cover screen: an
            //      About sheet, hung on an element the cover already draws,
            //      naming Miles and that cover's own gesture. Note what this
            //      is NOT — no Play policy text requires an on-screen
            //      affordance. Deceptive Behavior asks that functionality not
            //      be "hidden, dormant, or undocumented" and points at the
            //      STORE LISTING for the remedy (item 4); the persistent-
            //      notification-and-unique-icon rule belongs to Stalkerware
            //      and Monitoring Applications, which is about monitoring
            //      another person, not about a cover the owner chose. This
            //      sentence used to read "a visible way out", was taken for
            //      policy, and produced a bare unlabelled ring on all nine
            //      covers — conspicuous to a stranger and mute to the owner.
            //      The real requirement is a product one: a forgotten gesture
            //      must never be a lockout.
            //   4. the feature described in the store listing, with the picker
            //      in at least one screenshot
            //   5. the unlock gesture + a test account in Console > App access
            // Items 4 and 5 are Console-side; see PLAY-READINESS-AUDIT.md.
            buildConfigField("boolean", "DISGUISE_ENABLED", "true")
            // Installs as Miles, under its own name and icon, and stays that
            // way until the owner asks otherwise.
            buildConfigField("boolean", "PLAIN_DEFAULT", "true")
            // No fallback: the taskGraph check below stops the build instead of
            // handing back an artifact Play will reject.
            if (hasReleaseKey) signingConfig = signingConfigs.getByName("release")
        }
    }

    buildTypes {
        release {
            // R8 (minify + resource shrink) is OFF here, which is the SIDELOAD
            // channel's setting and nothing else: R8 can strip reflection/JNI
            // paths in WebRTC and ML Kit that fail only on a real device, so
            // the unshrunk build is what you reach for to prove a crash is not
            // the shrinker's doing. The play channel turns both on in the
            // androidComponents block below and is what real people install
            // (BRAIN §263) — a tester must run the code that ships, shrinker
            // included, or the shrinker is first exercised in production.
            isMinifyEnabled = false
            isShrinkResources = false
            // Explicit, though it is AGP 8.13's default for a non-debuggable
            // variant: the four .sym files Play does get (libapp, libflutter,
            // libdartjni, libxeno_native) depend on it, and an AGP default
            // change would drop them silently. It cannot add symbols for the
            // seven prebuilt, already-stripped libs (WebRTC, Mapbox, CameraX,
            // DataStore, libc++) — their vendors publish none (BRAIN §258).
            ndk { debugSymbolLevel = "SYMBOL_TABLE" }
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
    // The sideload RELEASE APK is arm64-only (debug is untouched, so an
    // emulator still runs). The play channel is arm64-only
    // ONLY when -PmilesPlayApkArm64 is passed, which tool/release.sh does for
    // the tester APK and never for the Console bundle — the bundle keeps every
    // ABI because Play splits per device itself. Both strips live in the
    // androidComponents block below; the guard that keeps the property off the
    // bundle is at the bottom of this file.
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

    // The shipped sideload APK must carry ONE architecture, because a partial
    // one is worse than none. Measured on build 64, straight out of Miles.apk:
    //
    //     lib/arm64-v8a/    11 libs, libapp.so and libflutter.so among them
    //     lib/armeabi-v7a/   9 libs, NEITHER
    //     lib/x86_64/        9 libs, NEITHER
    //
    // tool/release.sh passes --target-platform android-arm64, and that flag
    // filters only FLUTTER's own libraries. mapbox, WebRTC/jingle and datastore
    // hand AGP finished .so files for all three ABIs out of their AARs, so
    // lib/armeabi-v7a/ survived — non-empty, and that is the whole of what the
    // installer looks at. A 32-bit phone therefore INSTALLED build 64 happily
    // and then died the instant the Flutter loader went looking for an engine
    // that was never packaged. An icon that crashes on every tap is strictly
    // worse than the "app not compatible with this device" the same phone would
    // have been told had lib/armeabi-v7a/ simply not existed.
    //
    // ndk { abiFilters } is the obvious lever and it is the wrong one: measured
    // inert on build 47, because it governs only what AGP itself builds through
    // the NDK and never what is copied into jniLibs already compiled. Packaging
    // excludes are applied where the APK is written, so they catch every .so no
    // matter who produced it. There is no include list, hence the enumeration —
    // it is every ABI Android has ever defined except the one we keep, so an
    // AAR that starts shipping a new one cannot quietly reopen this.
    //
    // Deliberately NOT in the android { packaging } block: that block cannot
    // tell the channels apart, and the Console AAB must keep every ABI — Play
    // splits per device, so each one removed is reach lost for nobody's
    // benefit. The play channel does get this list, but only for the tester
    // APK and only behind -PmilesPlayApkArm64, and the taskGraph check at the
    // bottom of this file stops the build if that property is ever present
    // while the bundle is being packaged. Release-only for the same reason in
    // the other direction — `flutter run` on an x86_64 emulator builds a debug
    // APK for the emulator's own architecture, and stripping it here would
    // make the sideload flavour undebuggable.
    val onlyArm64 = listOf(
        "lib/armeabi/**",
        "lib/armeabi-v7a/**",
        "lib/x86/**",
        "lib/x86_64/**",
        "lib/mips/**",
        "lib/mips64/**",
        "lib/riscv64/**",
    )
    onVariants(
        selector().withFlavor("channel", "sideload").withBuildType("release"),
    ) { variant ->
        variant.packaging.jniLibs.excludes.addAll(onlyArm64)
    }

    // The play channel builds TWO artifacts from one variant, and they want
    // opposite things from the ABI list:
    //
    //   the AAB   — every ABI, because Play splits per device and each one
    //               removed is reach lost for nobody's benefit;
    //   the APK   — one ABI, because it is handed to a tester whole, and the
    //               measurement above says a partial APK installs on a 32-bit
    //               phone and then dies on a missing engine. One ABI means an
    //               incompatible phone is told so by the installer instead.
    //
    // A variant cannot know which task will consume it, so the caller says:
    // tool/release.sh passes -PmilesPlayApkArm64 for the tester APK and
    // nothing at all for the Console bundle. An arm64 handset gets the same
    // set of libraries either way — this is what Play would have delivered it.
    if (providers.gradleProperty("milesPlayApkArm64").isPresent) {
        onVariants(
            selector().withFlavor("channel", "play").withBuildType("release"),
        ) { variant ->
            variant.packaging.jniLibs.excludes.addAll(onlyArm64)
        }
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

    // -PmilesPlayApkArm64 strips every non-arm64 ABI from the play VARIANT,
    // and a variant's merged jniLibs feed mergePlayReleaseNativeLibs, which
    // packages the BUNDLE as well as the APK. Nothing about the property says
    // "APK" — only the command the caller happened to run does, and that is
    // not a guarantee. Reaching the bundle it would upload a Console artifact
    // serving arm64 devices alone: accepted by Play, shrinking reach for every
    // other phone, and visible nowhere but Play's own device numbers weeks
    // later. So the property is refused on a bundle build rather than applied
    // to the wrong artifact. This catches every route it can arrive by — typed
    // on the command line, left in gradle.properties, or exported as
    // ORG_GRADLE_PROJECT_milesPlayApkArm64.
    if (allTasks.any { it.project == project && it.name == "packagePlayReleaseBundle" } &&
        providers.gradleProperty("milesPlayApkArm64").isPresent
    ) {
        throw GradleException(
            "-PmilesPlayApkArm64 strips non-arm64 ABIs from the play variant, " +
                "and the variant feeds the bundle too. It would cripple the " +
                "Console AAB's reach. It is for the tester APK only. Build the " +
                "bundle without it.",
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

// (No version pins needed — AGP 8.13 + Kotlin 2.2.20 supports the latest
// transitive deps pulled by the plugin chain.)
