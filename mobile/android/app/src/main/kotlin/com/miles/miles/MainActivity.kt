package com.miles.miles

import android.app.Activity
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.app.PictureInPictureParams
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.os.SystemClock
import android.provider.DocumentsContract
import android.provider.Settings
import android.util.Rational
import android.view.KeyEvent
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.util.concurrent.Executors

// Must extend FlutterFragmentActivity (NOT FlutterActivity): local_auth's
// biometric prompt requires a FragmentActivity host. With FlutterActivity,
// authenticate() throws `no_fragment_activity` and silently fails — which is
// why the app-lock could lock but never unlock.
class MainActivity : FlutterFragmentActivity() {

    private var secureFlagSet = false

    // Text shared into the app from another app's share sheet, held until Dart
    // asks for it.
    //
    // PULL, not push: the engine may not be attached when the intent arrives —
    // a share that cold-starts the app delivers the intent before any Dart is
    // running — and pushing into a channel that does not exist yet drops the
    // link silently. Dart asks on start and on resume, and takes it once.
    private var pendingSharedText: String? = null

    // Set while the activity is in Android's own picture-in-picture window.
    //
    // Read by the Dart side so the disguise cover does NOT come up. The cover
    // is raised on every background, and PiP counts as one — without this
    // exemption, minimising a call out of the app would show the News cover in
    // the floating window instead of her face, which is both useless and a
    // louder tell than the call ever was.
    private var inPip = false
    private var pipChannel: MethodChannel? = null

    // Forwards hardware volume-key presses to Dart for the emergency-lock combo
    // + stealth-scrim dismiss. Android consumes volume keys before Flutter's
    // key pipeline sees them, so we must bridge them ourselves.
    private var volumeChannel: MethodChannel? = null

    // ── Data export (SAF) ──
    //
    // The Dart result waiting on the ACTION_OPEN_DOCUMENT_TREE picker. Classic
    // onActivityResult rather than registerForActivityResult: the launcher API
    // must be registered before the activity is STARTED, and this channel is
    // wired in configureFlutterEngine — which for a warm engine can run after
    // that. Flutter's own plugins ride onActivityResult already; claiming one
    // request code beside them is the supported shape.
    private var pendingFolderPick: MethodChannel.Result? = null

    // Open streams into the user's chosen folder, keyed by the handle Dart
    // holds. Everything that touches this map (and the counter) runs on
    // [exportExecutor] — a SINGLE thread, which is both the confinement that
    // makes the map safe without locks and the ordering guarantee that a
    // writeChunk can never land after its closeFile. The Dart side awaits each
    // call anyway; the executor's job is keeping half-megabyte writes off the
    // platform UI thread, where they would jank every other channel on it.
    private val exportStreams = HashMap<Int, OutputStream>()
    private var nextExportHandle = 1
    private val exportExecutor = Executors.newSingleThreadExecutor()
    private val exportMain = Handler(Looper.getMainLooper())

    private companion object {
        const val REQUEST_EXPORT_TREE = 4207
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        when (keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> volumeChannel?.invokeMethod("volume", "up")
            KeyEvent.KEYCODE_VOLUME_DOWN -> volumeChannel?.invokeMethod("volume", "down")
        }
        // Return super so the system still adjusts the volume normally.
        return super.onKeyDown(keyCode, event)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureSharedText(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureSharedText(intent)
    }

    override fun onDestroy() {
        super.onDestroy()
        // Streams die with the activity. A recreation mid-export (rotation, a
        // kill in the background) invalidates every handle Dart holds; each
        // later writeChunk then fails and the Dart run counts that file as a
        // failure — which is the truth. Nothing to report from here: the
        // process is on its way out.
        exportExecutor.execute {
            for (stream in exportStreams.values) {
                try {
                    stream.close()
                } catch (e: Exception) {
                    // Closing a stream whose file is already lost; the Dart
                    // summary carries the failure.
                }
            }
            exportStreams.clear()
        }
        exportExecutor.shutdown()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        val result = pendingFolderPick
        if (requestCode != REQUEST_EXPORT_TREE || result == null) {
            // Not ours — every plugin's picker still arrives through here.
            // The pendingFolderPick check matters as much as the code: some
            // plugins (file_picker) register runtime request codes by hashing,
            // and a hash landing on 4207 while no export pick is open must
            // reach its own plugin, not be swallowed here.
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        pendingFolderPick = null
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri == null) {
            // Backed out of the picker. An ordinary answer, not an error —
            // the Dart side reads null as "nothing chosen, do nothing".
            result.success(null)
            return
        }
        try {
            // Persist the grant, or it dies with this task: the export walks
            // thousands of files and the app can be relaunched mid-run, and a
            // tree URI without a persisted grant answers every reopen with
            // SecurityException.
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
            result.success(uri.toString())
        } catch (e: Exception) {
            // Class only, like runExportIo: a SecurityException's message can
            // embed the folder URI the user picked.
            result.error("no_permission", e.javaClass.simpleName, null)
        }
    }

    /// Instagram, TikTok and the rest all share a plain-text link.
    private fun captureSharedText(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        if (intent.type != "text/plain") return
        val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return
        if (text.isNotBlank()) pendingSharedText = text
    }

    /// Android asks this the moment the user presses home or swipes up. A call
    /// that is running should follow them out rather than being backgrounded.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (pipWanted) enterPip()
    }

    private var pipWanted = false

    private fun enterPip(): Boolean {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.O) {
            return false
        }
        return try {
            enterPictureInPictureMode(
                PictureInPictureParams.Builder()
                    // Portrait-ish, matching the in-app window so the handoff
                    // between them does not jump.
                    .setAspectRatio(Rational(3, 4))
                    .build()
            )
        } catch (e: Exception) {
            false
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: android.content.res.Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        inPip = isInPictureInPictureMode
        pipChannel?.invokeMethod("pip", isInPictureInPictureMode)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pipChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "miles/pip")
        pipChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                // Dart arms this while a call is live, so pressing home takes
                // the call with you instead of dropping it behind the cover.
                "setWanted" -> {
                    pipWanted = call.argument<Boolean>("wanted") ?: false
                    result.success(null)
                }
                "enterNow" -> result.success(enterPip())
                "isInPip" -> result.success(inPip)
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "miles/share_intent")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Taken once. Leaving it set would re-add the same link on
                    // every resume for the rest of the session.
                    "takeSharedText" -> {
                        val text = pendingSharedText
                        pendingSharedText = null
                        result.success(text)
                    }
                    else -> result.notImplemented()
                }
            }
        volumeChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "miles/volume_keys")
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "miles/secure_screen")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSecure" -> {
                        val enable = call.argument<Boolean>("enable") ?: false
                        runOnUiThread {
                            if (enable) {
                                window.setFlags(
                                    WindowManager.LayoutParams.FLAG_SECURE,
                                    WindowManager.LayoutParams.FLAG_SECURE
                                )
                                secureFlagSet = true
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                                secureFlagSet = false
                            }
                            result.success(null)
                        }
                    }
                    "isSecure" -> result.success(secureFlagSet)
                    else -> result.notImplemented()
                }
            }

        // Launcher disguise: exactly one <activity-alias> is enabled at a time,
        // and its manifest label + icon are what the launcher shows. This is the
        // only supported way to change an app's icon/name at runtime.
        //
        // Order matters and is not cosmetic: we ENABLE the new alias before
        // DISABLING any other. Doing it the other way round leaves a window
        // where no launcher component is enabled, and if the process is killed
        // in that window the app is gone from the launcher with no way back.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "miles/disguise")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Both channels ship the aliases now. What differs is the
                    // one that starts enabled: sideload installs as News, play
                    // installs as Miles and only leaves it if the owner picks a
                    // cover in Settings.
                    "isEnabled" -> result.success(BuildConfig.DISGUISE_ENABLED)
                    // True where the app's own identity is a real, selectable
                    // launcher component (AliasMiles) rather than the absence
                    // of one — so Dart knows there is something to switch back
                    // TO, and knows not to prompt for a cover unasked.
                    "isPlainDefault" -> result.success(BuildConfig.PLAIN_DEFAULT)
                    "setAlias" -> {
                        val target = call.argument<String>("aliasId")
                        val all = call.argument<List<String>>("all")
                        if (target.isNullOrBlank() || all.isNullOrEmpty()) {
                            result.error("bad_args", "aliasId and all are required", null)
                            return@setMethodCallHandler
                        }
                        // Refuse anything not in the declared set — enabling a
                        // component that does not exist throws, and disabling
                        // everything else would strand the user.
                        if (!all.contains(target)) {
                            result.error("unknown_alias", "$target is not a declared alias", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val pm = packageManager
                            fun component(id: String) =
                                ComponentName(packageName, "$packageName.Alias$id")

                            // 1. Enable the new identity first.
                            pm.setComponentEnabledSetting(
                                component(target),
                                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                                PackageManager.DONT_KILL_APP
                            )
                            // 2. Only then retire the others.
                            all.filter { it != target }.forEach { id ->
                                pm.setComponentEnabledSetting(
                                    component(id),
                                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                                    PackageManager.DONT_KILL_APP
                                )
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            // Leave whatever was enabled enabled. A failed swap
                            // must not cost the user their launcher entry.
                            result.error("switch_failed", e.javaClass.simpleName, null)
                        }
                    }
                    "currentAlias" -> {
                        val all = call.argument<List<String>>("all") ?: emptyList()
                        // DEFAULT counts as enabled, and that is the whole fix.
                        // getComponentEnabledSetting reports DEFAULT (0) for a
                        // component nobody has ever toggled — which is every
                        // alias on a FRESH INSTALL, including the one the
                        // manifest ships android:enabled="true". Matching only
                        // ENABLED (1) therefore found nothing on exactly the
                        // install this has to be right for, returned null, and
                        // sent reconcile() down its fallback path to the old
                        // default: the app opened on the News cover under its
                        // own name and icon.
                        //
                        // DEFAULT is only correct for an alias the manifest
                        // enables, so it is checked second — an explicitly
                        // enabled alias still wins, which is what keeps a
                        // user's chosen cover ahead of the shipped one.
                        val active = all.firstOrNull { id ->
                            packageManager.getComponentEnabledSetting(
                                ComponentName(packageName, "$packageName.Alias$id")
                            ) == PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                        } ?: all.firstOrNull { id ->
                            packageManager.getComponentEnabledSetting(
                                ComponentName(packageName, "$packageName.Alias$id")
                            ) == PackageManager.COMPONENT_ENABLED_STATE_DEFAULT
                        }
                        result.success(active)
                    }
                    else -> result.notImplemented()
                }
            }

        // Everything the "Device Info" disguise shows that Dart cannot reach.
        // No new package and no new permission: battery is a sticky broadcast,
        // storage is StatFs, memory is ActivityManager, and the network kind
        // needs ACCESS_NETWORK_STATE, which this app already holds.
        //
        // Every value is the handset's own live state, which is what makes that
        // cover self-verifying — there is nothing here to fabricate.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "miles/device_stats")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "read" -> try {
                        result.success(deviceStats())
                    } catch (e: Exception) {
                        // The Dart side renders a full screen without us; a
                        // cover that shows an error dialog is a cover that
                        // gets looked at twice.
                        result.error("stats_failed", e.javaClass.simpleName, null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Full-screen-intent permission (Android 14 / API 34+). Below 34 it's
        // implicitly granted; from 34 the user must allow it in system settings.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "miles/fsi")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canUseFullScreenIntent" -> {
                        if (Build.VERSION.SDK_INT >= 34) {
                            val nm = getSystemService(NotificationManager::class.java)
                            result.success(nm.canUseFullScreenIntent())
                        } else {
                            result.success(true)
                        }
                    }
                    "openSettings" -> {
                        if (Build.VERSION.SDK_INT >= 34) {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                                Uri.parse("package:$packageName")
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // App-level queries: which channel this build is (the release gate's
        // floor) and the notification-channel settings deep link. The name is
        // the self-updater's, which once lived here too and is retired.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "miles/updater")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Which channel this build is — "sideload" or "play",
                    // verbatim from the flavour name AGP wrote into
                    // BuildConfig, so it cannot drift from the artifact the
                    // way a hand-set field could. The release gate uses it to
                    // pick which floor (min_build vs min_build_play) applies
                    // to this install.
                    "channel" -> result.success(BuildConfig.FLAVOR)
                    // How the last processes died, from the OS's own record
                    // (API 30+): crash, native crash, ANR, init failure. The
                    // app ships no crash SDK on purpose, and without this a
                    // SIGSEGV in WebRTC or Mapbox left nothing anywhere. Dart
                    // files what is newer than its watermark to client_errors.
                    // The trace (ANR stacks, native tombstone head) is capped;
                    // it holds thread and frame names, never user content.
                    "exitReasons" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                            result.success(emptyList<Map<String, Any?>>())
                            return@setMethodCallHandler
                        }
                        try {
                            val am = getSystemService(ActivityManager::class.java)
                            val list = am.getHistoricalProcessExitReasons(packageName, 0, 20)
                                .map { info ->
                                    val wantsTrace = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                                        (info.reason == ApplicationExitInfo.REASON_ANR ||
                                            info.reason == ApplicationExitInfo.REASON_CRASH_NATIVE)
                                    // The head of the trace, read as such: an
                                    // ANR trace can run to megabytes, and this
                                    // handler shares the main thread with the
                                    // release gate's 2 s 'channel' call.
                                    val trace = if (wantsTrace) {
                                        try {
                                            info.traceInputStream?.bufferedReader()?.use { r ->
                                                val head = CharArray(1900)
                                                val n = r.read(head)
                                                if (n > 0) String(head, 0, n) else null
                                            }
                                        } catch (e: Exception) {
                                            null
                                        }
                                    } else null
                                    mapOf(
                                        "reason" to info.reason,
                                        "description" to info.description,
                                        "timestamp" to info.timestamp,
                                        "importance" to info.importance,
                                        "trace" to trace,
                                    )
                                }
                            result.success(list)
                        } catch (e: Exception) {
                            result.error("exit_reasons_failed", e.javaClass.simpleName, null)
                        }
                    }
                    // Android's own per-notification-type controls (sound,
                    // vibration, importance) already exist as channel pages in
                    // system settings; this deep-links straight to one instead
                    // of asking the user to dig for it. Channels are created
                    // lazily — the message channel by the first background
                    // push, the timer channel by the Timer cover — and firing
                    // the channel intent for an id the OS has never seen shows
                    // a broken page on several OEMs, so an unknown or null id
                    // falls back to the app's notification page, which lists
                    // every channel that does exist.
                    "notificationChannelSettings" -> {
                        val channelId = call.argument<String>("id")
                        try {
                            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                val exists = channelId != null &&
                                    getSystemService(NotificationManager::class.java)
                                        .getNotificationChannel(channelId) != null
                                if (exists) {
                                    Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                                        .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                                        .putExtra(Settings.EXTRA_CHANNEL_ID, channelId)
                                } else {
                                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                        .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                                }
                            } else {
                                // Pre-O has no channels; the app-info page is
                                // where its notification toggle lives.
                                Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.parse("package:$packageName")
                                )
                            }
                            startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("settings_failed", e.javaClass.simpleName, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Data export: streams decrypted copies into a folder the user picked.
        // SAF is the only way to write somewhere the user chose that survives
        // scoped storage, needs no permission dialog of its own, and keeps
        // working on every Android this app runs on. The protocol is
        // deliberately dumb — open, append, close, by handle — because the
        // policy (what to export, how to name it, what a failure means) all
        // lives on the Dart side where the repositories are. Chunked so a
        // multi-GB video is never in memory on either side of the channel.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "miles/export")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickFolder" -> {
                        if (pendingFolderPick != null) {
                            result.error("busy", "a folder pick is already open", null)
                            return@setMethodCallHandler
                        }
                        pendingFolderPick = result
                        try {
                            startActivityForResult(
                                Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                                ),
                                REQUEST_EXPORT_TREE
                            )
                        } catch (e: Exception) {
                            // No documents UI on this device. Answered as an
                            // error, not a null: null means "the user said no",
                            // and this is "the user was never asked". Class
                            // only, like runExportIo — an ActivityNotFound
                            // message can carry intent details.
                            pendingFolderPick = null
                            result.error("no_picker", e.javaClass.simpleName, null)
                        }
                    }
                    "createFile" -> {
                        val treeUri = call.argument<String>("treeUri")
                        val relativePath = call.argument<String>("relativePath")
                        val mime = call.argument<String>("mime")
                        if (treeUri.isNullOrBlank() || relativePath.isNullOrBlank() ||
                            mime.isNullOrBlank()
                        ) {
                            result.error(
                                "bad_args", "treeUri, relativePath and mime are required", null
                            )
                            return@setMethodCallHandler
                        }
                        runExportIo(result) { exportCreateFile(treeUri, relativePath, mime) }
                    }
                    "writeChunk" -> {
                        val id = call.argument<Int>("id")
                        val bytes = call.argument<ByteArray>("bytes")
                        if (id == null || bytes == null) {
                            result.error("bad_args", "id and bytes are required", null)
                            return@setMethodCallHandler
                        }
                        runExportIo(result) {
                            val stream = exportStreams[id]
                                ?: throw IllegalStateException("no open file for handle $id")
                            stream.write(bytes)
                            null
                        }
                    }
                    "closeFile" -> {
                        val id = call.argument<Int>("id")
                        if (id == null) {
                            result.error("bad_args", "id is required", null)
                            return@setMethodCallHandler
                        }
                        runExportIo(result) {
                            // remove() before close(): even a close that throws
                            // must not leave a dead handle a retry could write
                            // into.
                            val stream = exportStreams.remove(id)
                                ?: throw IllegalStateException("no open file for handle $id")
                            try {
                                stream.flush()
                            } finally {
                                stream.close()
                            }
                            null
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Runs [op] on the export thread and answers on the platform thread,
    /// which is the only thread a MethodChannel.Result may be completed from.
    /// Only the exception's CLASS crosses back as the code: an IOException's
    /// message can name the folder the user picked, and the Dart side reports
    /// failure classes, never paths.
    private fun runExportIo(result: MethodChannel.Result, op: () -> Any?) {
        exportExecutor.execute {
            try {
                val value = op()
                exportMain.post { result.success(value) }
            } catch (e: Exception) {
                exportMain.post {
                    result.error("io_failed", e.javaClass.simpleName, null)
                }
            }
        }
    }

    /// Creates every directory along [relativePath] under [treeUriStr], then
    /// the file itself, and answers the handle Dart appends through PLUS the
    /// display name the provider actually gave the file. The provider owns
    /// that name — a taken one gains a " (1)" suffix, and some providers
    /// append the mime's extension — and Dart's manifests must point at the
    /// file that exists, not the one that was asked for.
    ///
    /// DocumentsContract rather than DocumentFile: DocumentFile.findFile lists
    /// the whole directory per lookup, and the export creates hundreds of files
    /// under the same few directories. This walks each directory level once per
    /// call with one child query, which is the same work DocumentFile does
    /// internally minus the per-file re-listing.
    private fun exportCreateFile(
        treeUriStr: String,
        relativePath: String,
        mime: String
    ): Map<String, Any> {
        val treeUri = Uri.parse(treeUriStr)
        val segments = relativePath.split('/').filter { it.isNotBlank() }
        require(segments.isNotEmpty()) { "relativePath has no segments" }
        var parentDoc = DocumentsContract.getTreeDocumentId(treeUri)
        for (dir in segments.dropLast(1)) {
            parentDoc = findOrCreateDir(treeUri, parentDoc, dir)
        }
        val parentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, parentDoc)
        // If the name is already taken the provider appends a suffix rather
        // than overwriting — the right default for an export, where clobbering
        // a file from a previous run would silently shorten it.
        val fileUri = DocumentsContract.createDocument(
            contentResolver, parentUri, mime, segments.last()
        ) ?: throw IllegalStateException("provider refused to create ${segments.last()}")
        // Read the real name back off the created document. A provider that
        // answers no display name leaves the requested one standing, which is
        // no worse than not asking.
        var name = segments.last()
        contentResolver.query(
            fileUri,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null, null, null
        )?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) name = c.getString(0)
        }
        val stream = contentResolver.openOutputStream(fileUri, "w")
            ?: throw IllegalStateException("provider opened no stream")
        val id = nextExportHandle++
        exportStreams[id] = stream
        return mapOf("id" to id, "name" to name)
    }

    /// The document id of the child directory [name] under [parentDoc],
    /// creating it if it does not exist yet.
    private fun findOrCreateDir(treeUri: Uri, parentDoc: String, name: String): String {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDoc)
        contentResolver.query(
            children,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE
            ),
            null, null, null
        )?.use { c ->
            while (c.moveToNext()) {
                if (c.getString(1) == name &&
                    c.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR
                ) {
                    return c.getString(0)
                }
            }
        }
        val parentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, parentDoc)
        val made = DocumentsContract.createDocument(
            contentResolver, parentUri, DocumentsContract.Document.MIME_TYPE_DIR, name
        ) ?: throw IllegalStateException("provider refused to create directory $name")
        return DocumentsContract.getDocumentId(made)
    }

    private fun deviceStats(): Map<String, Any?> {
        val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1

        val storage = StatFs(Environment.getDataDirectory().path)
        val memory = ActivityManager.MemoryInfo()
        getSystemService(ActivityManager::class.java).getMemoryInfo(memory)

        return mapOf(
            "batteryPercent" to if (level >= 0 && scale > 0) level * 100 / scale else -1,
            "charging" to (status == BatteryManager.BATTERY_STATUS_CHARGING ||
                status == BatteryManager.BATTERY_STATUS_FULL),
            "storageTotal" to storage.totalBytes,
            "storageFree" to storage.availableBytes,
            "ramTotal" to memory.totalMem,
            "ramFree" to memory.availMem,
            "uptimeMs" to SystemClock.elapsedRealtime(),
            "model" to Build.MODEL,
            "manufacturer" to Build.MANUFACTURER,
            "androidRelease" to Build.VERSION.RELEASE,
            "sdkInt" to Build.VERSION.SDK_INT,
            "buildId" to Build.DISPLAY,
            "network" to networkKind()
        )
    }

    private fun networkKind(): String {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return "Unknown"
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return "Offline"
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "Mobile"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "Ethernet"
            else -> "Connected"
        }
    }
}
