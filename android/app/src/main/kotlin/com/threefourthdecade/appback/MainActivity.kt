package com.threefourthdecade.appback

import android.content.ComponentName
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.IBinder
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import rikka.shizuku.Shizuku
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.threefourthdecade.appback/channel"

    // Portable backups live here: shell-writable, user-transferable, survives app uninstall.
    private val BACKUP_DIR = "/sdcard/AppBack"

    // Markers for which packages have an on-device bmgr snapshot (shell-writable).
    private val SNAP_DIR = "/data/local/tmp/appback_snapshots"

    // Google's cloud backup transport (uploads to the user's Google Drive backup).
    private val GMS_TRANSPORT = "com.google.android.gms/.backup.BackupTransportService"

    private var pendingPermissionResult: MethodChannel.Result? = null

    // Reference to our compiled AIDL interface instance
    private var userService: IUserService? = null

    // The Dart bindService() call is held here until the binder actually arrives
    // (onServiceConnected) or we give up (timeout). bindUserService is asynchronous:
    // it returns immediately and the connection lands later on the main thread.
    private var pendingBindResult: MethodChannel.Result? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var bindTimeout: Runnable? = null

    private fun clearBindTimeout() {
        bindTimeout?.let { mainHandler.removeCallbacks(it) }
        bindTimeout = null
    }

    // Human-readable snapshot of Shizuku's state, attached to bind errors so the
    // failure reason is visible on-device (useful on OEM ROMs that throttle Shizuku).
    private fun shizukuDiagnostics(): String {
        val sb = StringBuilder()
        try {
            val ping = try { Shizuku.pingBinder() } catch (e: Exception) { false }
            sb.append("pingBinder: ").append(ping).append("\n")
            if (ping) {
                val uid = try { Shizuku.getUid() } catch (e: Exception) { -1 }
                sb.append("uid: ").append(uid)
                    .append(if (uid == 0) " (root)" else if (uid == 2000) " (adb/shell)" else " (?)")
                    .append("\n")
                sb.append("version: ").append(try { Shizuku.getVersion() } catch (e: Exception) { -1 }).append("\n")
                val perm = try {
                    Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
                } catch (e: Exception) { false }
                sb.append("permissionGranted: ").append(perm).append("\n")
                sb.append("preV11: ").append(try { Shizuku.isPreV11() } catch (e: Exception) { "?" }).append("\n")
            } else {
                sb.append("→ Shizuku binder not available. Is Shizuku running?\n")
            }
        } catch (e: Exception) {
            sb.append("diagnostics error: ").append(e.message).append("\n")
        }
        sb.append("userServiceBound: ").append(userService != null)
        return sb.toString()
    }

    // Convert any Drawable (including adaptive/vector icons) into a Bitmap we can
    // PNG-encode. BitmapDrawable is used directly; others are rendered onto a canvas.
    private fun drawableToBitmap(drawable: Drawable): Bitmap {
        if (drawable is BitmapDrawable && drawable.bitmap != null) {
            return drawable.bitmap
        }
        val width = if (drawable.intrinsicWidth > 0) drawable.intrinsicWidth else 96
        val height = if (drawable.intrinsicHeight > 0) drawable.intrinsicHeight else 96
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, canvas.width, canvas.height)
        drawable.draw(canvas)
        return bitmap
    }

    // Connection lifecycle handler for Shizuku's remote process
    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            // Converts the raw binder token into our generated interface layout.
            userService = if (service != null && service.pingBinder()) {
                IUserService.Stub.asInterface(service)
            } else {
                null
            }
            // Resolve the awaiting Dart call now that the connection is truly ready.
            clearBindTimeout()
            pendingBindResult?.let { res ->
                if (userService != null) {
                    res.success(true)
                } else {
                    res.error("BIND_DEAD", "Service connected but the binder was not alive.", null)
                }
            }
            pendingBindResult = null
        }
        override fun onServiceDisconnected(name: ComponentName?) {
            userService = null
        }
    }

    private val shizukuPermissionListener = Shizuku.OnRequestPermissionResultListener { requestCode, grantResult ->
        if (requestCode == 100) {
            if (grantResult == PackageManager.PERMISSION_GRANTED) {
                pendingPermissionResult?.success(true)
            } else {
                pendingPermissionResult?.success(false)
            }
            pendingPermissionResult = null 
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        Shizuku.addRequestPermissionResultListener(shizukuPermissionListener)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestShizukuPermission" -> {
                    if (!Shizuku.pingBinder()) {
                        result.error("SHIZUKU_NOT_READY", "Shizuku service is not running or binder hasn't been received yet.", null)
                        return@setMethodCallHandler
                    }

                    try {
                        if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                            result.success(true)
                        } else {
                            pendingPermissionResult = result
                            Shizuku.requestPermission(100) 
                        }
                    } catch (e: IllegalStateException) {
                        result.error("SHIZUKU_ERROR", e.message, null)
                    }
                }
                
                "bindService" -> {
                    // Already connected? Resolve immediately.
                    if (userService != null) {
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    // Don't start a second bind while one is pending.
                    if (pendingBindResult != null) {
                        result.error("BIND_IN_PROGRESS", "A bind is already in progress.", null)
                        return@setMethodCallHandler
                    }
                    try {
                        // Same known-good args as before (daemon(false), fixed tag).
                        val args = Shizuku.UserServiceArgs(
                            ComponentName(context, ShizukuShellService::class.java.name)
                        ).daemon(false).processNameSuffix("privileged_shell").tag("backup_service")

                        // Hold the Dart result; onServiceConnected resolves it. Add a timeout
                        // so a throttled/failed spawn surfaces as an error instead of hanging
                        // (Shizuku's bindUserService can silently never connect — see their
                        // issue #475).
                        pendingBindResult = result
                        bindTimeout = Runnable {
                            if (pendingBindResult != null) {
                                pendingBindResult?.error(
                                    "BIND_TIMEOUT",
                                    "Service did not connect within 30s (device may be throttling the Shizuku process).",
                                    shizukuDiagnostics()
                                )
                                pendingBindResult = null
                            }
                        }
                        mainHandler.postDelayed(bindTimeout!!, 30_000)

                        Shizuku.bindUserService(args, serviceConnection)
                        // No result here — resolved by the callback or the timeout.
                    } catch (e: Exception) {
                        clearBindTimeout()
                        pendingBindResult = null
                        result.error("BIND_FAILED", e.message, shizukuDiagnostics())
                    }
                }

                "runCommand" -> {
                    val cmd = call.argument<String>("command") ?: ""
                    if (userService != null) {
                        // Offload shell interaction execution away from the primary UI thread frame
                        Thread {
                            val output = userService!!.runShellCommand(cmd)
                            runOnUiThread { result.success(output) }
                        }.start()
                    } else {
                        result.error("NOT_CONNECTED", "UserService is not bound yet or active.", null)
                    }
                }

                "backupAppData" -> {
                    val targetPackage = call.argument<String>("package_name")
                    if (targetPackage == null) {
                        result.error("INVALID_ARGS", "Missing package name", null)
                        return@setMethodCallHandler
                    }
                    if (userService == null) {
                        result.error("NOT_CONNECTED", "UserService is not bound.", null)
                        return@setMethodCallHandler
                    }

                    Thread {
                        try {
                            // ON-DEVICE snapshot via bmgr + LocalTransport.
                            //
                            // Unlike `bu`/`adb backup` (which Android 12+ blocks for
                            // non-debuggable apps), `bmgr backupnow` uses the transport backup
                            // path and DOES capture the app's real data. The data lives in
                            // LocalTransport's own storage (system-owned) — we don't read it;
                            // we restore from it on the SAME device via `bmgr restore`.
                            val cmd =
                                "bmgr enable true >/dev/null; " +
                                "bmgr transport com.android.localtransport/.LocalTransport >/dev/null; " +
                                "RESULT=\$(bmgr backupnow $targetPackage 2>&1); " +
                                "if echo \"\$RESULT\" | grep -qi 'result: Success'; then " +
                                "  mkdir -p $SNAP_DIR && date > $SNAP_DIR/$targetPackage; fi; " +
                                "echo \"\$RESULT\" | tail -n 3"

                            val output = userService!!.runShellCommand(cmd) ?: ""

                            // "Backup finished with result: Success" means the snapshot captured.
                            val ok = output.contains("result: Success", ignoreCase = true) ||
                                     Regex("with result: Success", RegexOption.IGNORE_CASE).containsMatchIn(output)

                            runOnUiThread {
                                if (ok) {
                                    result.success("Snapshot captured for $targetPackage (on-device)")
                                } else {
                                    result.error(
                                        "BACKUP_FAILED",
                                        "bmgr backup did not report success. Raw:\n$output",
                                        null
                                    )
                                }
                            }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("BACKUP_ERROR", e.message, null) }
                        }
                    }.start()
                }


                "restoreAppData" -> {
                    val targetPackage = call.argument<String>("package_name")
                    if (targetPackage == null) {
                        result.error("INVALID_ARGS", "Missing package name", null)
                        return@setMethodCallHandler
                    }
                    if (userService == null) {
                        result.error("NOT_CONNECTED", "UserService is not bound.", null)
                        return@setMethodCallHandler
                    }

                    Thread {
                        try {
                            // ON-DEVICE restore via bmgr + LocalTransport.
                            //
                            // `bmgr restore <token> <pkg>` restores that package from the
                            // stored backup set. We read the current set token from
                            // `bmgr list sets` (LocalTransport keeps one set). We force-stop
                            // the app first so it reloads the restored data.
                            val cmd =
                                "bmgr enable true >/dev/null; " +
                                "bmgr transport com.android.localtransport/.LocalTransport >/dev/null; " +
                                // First line of `list sets` is the token (a hex/number), or 'No restore sets'.
                                "TOKEN=\$(bmgr list sets 2>/dev/null | head -n 1 | awk '{print \$1}'); " +
                                "echo \"TOKEN=\$TOKEN\"; " +
                                "if [ -z \"\$TOKEN\" ] || echo \"\$TOKEN\" | grep -qi 'No'; then echo 'NOSET'; else " +
                                "am force-stop $targetPackage; " +
                                "RESULT=\$(bmgr restore \$TOKEN $targetPackage 2>&1); " +
                                "echo \"\$RESULT\" | tail -n 3; fi"

                            val output = userService!!.runShellCommand(cmd) ?: ""

                            val ok = Regex("restore.*(complete|finished|Success)", RegexOption.IGNORE_CASE)
                                .containsMatchIn(output)

                            runOnUiThread {
                                when {
                                    output.contains("NOSET") ->
                                        result.error("NO_BACKUP",
                                            "No snapshot found. Back up this app first.", null)
                                    ok ->
                                        result.success("Restored $targetPackage from snapshot")
                                    else ->
                                        result.error("RESTORE_FAILED",
                                            "bmgr restore did not confirm success. Raw:\n$output", null)
                                }
                            }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("RESTORE_ERROR", e.message, null) }
                        }
                    }.start()
                }

                "cloudBackup" -> {
                    val targetPackage = call.argument<String>("package_name")
                    if (targetPackage == null) {
                        result.error("INVALID_ARGS", "Missing package name", null)
                        return@setMethodCallHandler
                    }
                    if (userService == null) {
                        result.error("NOT_CONNECTED", "UserService is not bound.", null)
                        return@setMethodCallHandler
                    }

                    Thread {
                        try {
                            // Cloud backup via Google's GMS transport → uploads app data to
                            // the user's Google account backup. Works on-demand (verified).
                            // Requires: Google backup enabled + a backup account configured
                            // (Settings > System > Backup). We enable the setting; the account
                            // must be set by the user once.
                            val cmd =
                                "settings put secure backup_enabled 1 >/dev/null; " +
                                "bmgr transport $GMS_TRANSPORT >/dev/null; " +
                                "bmgr init $GMS_TRANSPORT >/dev/null; " +
                                "bmgr backupnow $targetPackage 2>&1 | tail -n 4"

                            val output = userService!!.runShellCommand(cmd) ?: ""

                            val success = Regex("$targetPackage with result: Success",
                                RegexOption.IGNORE_CASE).containsMatchIn(output) ||
                                Regex("finished with result: Success",
                                    RegexOption.IGNORE_CASE).containsMatchIn(output)

                            runOnUiThread {
                                if (success) {
                                    result.success("Uploaded $targetPackage to cloud backup.")
                                } else {
                                    result.error(
                                        "CLOUD_BACKUP_FAILED",
                                        "Cloud upload not confirmed. Make sure Google Backup " +
                                            "is ON with an account (Settings > System > Backup).\n$output",
                                        null
                                    )
                                }
                            }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("CLOUD_BACKUP_ERROR", e.message, null) }
                        }
                    }.start()
                }

                "cloudRestore" -> {
                    val targetPackage = call.argument<String>("package_name")
                    if (targetPackage == null) {
                        result.error("INVALID_ARGS", "Missing package name", null)
                        return@setMethodCallHandler
                    }
                    if (userService == null) {
                        result.error("NOT_CONNECTED", "UserService is not bound.", null)
                        return@setMethodCallHandler
                    }

                    Thread {
                        try {
                            // Cloud restore via the GMS transport: pull the app's data back
                            // down from the user's Google account backup. Verified working
                            // on-demand ("restoreFinished: 0" == success). We read the restore
                            // set token from `bmgr list sets` and force-stop the app first.
                            val cmd =
                                "bmgr transport $GMS_TRANSPORT >/dev/null; " +
                                "am force-stop $targetPackage; " +
                                "TOKEN=\$(bmgr list sets 2>/dev/null | head -n 1 | awk '{print \$1}'); " +
                                "echo \"TOKEN=\$TOKEN\"; " +
                                "if [ -z \"\$TOKEN\" ] || echo \"\$TOKEN\" | grep -qi 'No'; then echo 'NOSET'; else " +
                                "bmgr restore \$TOKEN $targetPackage 2>&1 | tail -n 6; fi"

                            val output = userService!!.runShellCommand(cmd) ?: ""

                            // "restoreFinished: 0" is the success code from bmgr restore.
                            val ok = Regex("restoreFinished:\\s*0").containsMatchIn(output) ||
                                Regex("restore.*(complete|finished|Success)",
                                    RegexOption.IGNORE_CASE).containsMatchIn(output)

                            runOnUiThread {
                                when {
                                    output.contains("NOSET") ->
                                        result.error("NO_CLOUD_BACKUP",
                                            "No cloud backup set found. Upload to cloud first.", null)
                                    ok ->
                                        result.success("Restored $targetPackage from cloud backup.")
                                    else ->
                                        result.error("CLOUD_RESTORE_FAILED",
                                            "Cloud restore not confirmed.\n$output", null)
                                }
                            }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("CLOUD_RESTORE_ERROR", e.message, null) }
                        }
                    }.start()
                }

                "listApps" -> {
                    if (userService == null) {
                        result.error("NOT_CONNECTED", "UserService is not bound.", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            // List third-party (user-installed) packages. Prefix "package:" is stripped Dart-side.
                            val includeSystem = call.argument<Boolean>("include_system") ?: false
                            val flag = if (includeSystem) "" else "-3"
                            val cmd = "pm list packages $flag | sed 's/^package://' | sort"
                            val output = userService!!.runShellCommand(cmd) ?: ""
                            runOnUiThread { result.success(output) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("LIST_ERROR", e.message, null) }
                        }
                    }.start()
                }

                // Batch: human-readable labels for many packages at once.
                // Uses the app's own PackageManager (fast, no shell/Shizuku needed).
                // Returns lines of "packageName\tLabel". Missing/uninstalled packages
                // are simply omitted; Dart falls back to the package name.
                "getAppLabels" -> {
                    val packages = call.argument<List<String>>("packages") ?: emptyList()
                    Thread {
                        val pm = packageManager
                        val sb = StringBuilder()
                        for (pkg in packages) {
                            try {
                                val ai = pm.getApplicationInfo(pkg, 0)
                                val label = pm.getApplicationLabel(ai).toString()
                                sb.append(pkg).append('\t').append(label).append('\n')
                            } catch (e: Exception) {
                                // Not installed / no label — skip; Dart shows the package name.
                            }
                        }
                        runOnUiThread { result.success(sb.toString()) }
                    }.start()
                }

                // Lazy: a single package's launcher icon as a base64 PNG.
                // Called per-tile as the list scrolls, so the initial list stays instant.
                "getAppIcon" -> {
                    val pkg = call.argument<String>("package_name")
                    if (pkg == null) {
                        result.error("INVALID_ARGS", "Missing package name", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        val encoded = try {
                            val drawable: Drawable = packageManager.getApplicationIcon(pkg)
                            val bmp = drawableToBitmap(drawable)
                            val baos = ByteArrayOutputStream()
                            bmp.compress(Bitmap.CompressFormat.PNG, 100, baos)
                            Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP)
                        } catch (e: Exception) {
                            null
                        }
                        runOnUiThread { result.success(encoded) }
                    }.start()
                }

                "listBackups" -> {
                    if (userService == null) {
                        result.error("NOT_CONNECTED", "UserService is not bound.", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            // Emit "<package>\t<epochSeconds>" per package that has an
                            // on-device checkpoint marker. The epoch is the marker file's
                            // modification time = when the checkpoint was set.
                            val cmd =
                                "mkdir -p $SNAP_DIR; " +
                                "for f in $SNAP_DIR/*; do " +
                                "[ -e \"\$f\" ] || continue; " +
                                "TS=\$(stat -c %Y \"\$f\" 2>/dev/null || echo 0); " +
                                "echo \"\$(basename \"\$f\")\t\$TS\"; done"
                            val output = userService!!.runShellCommand(cmd) ?: ""
                            runOnUiThread { result.success(output) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("LIST_BACKUPS_ERROR", e.message, null) }
                        }
                    }.start()
                }



                "testNative" -> {
                    if (userService == null) {
                        result.success("UserService not bound yet. Connect first!")
                    } else {
                        Thread {
                            val output = userService!!.runShellCommand("echo bridge-ok")
                            runOnUiThread { result.success(output?.trim() ?: "no output") }
                        }.start()
                    }
                }



                else -> result.notImplemented()
            }
        }
    }
    
    override fun onDestroy() {
        Shizuku.removeRequestPermissionResultListener(shizukuPermissionListener)
        // Safely disconnect active system hook structures if current activity teardown happens
        try {
            if (userService != null) {
                // If you want to unbind manually on app close, uncomment below:
                // Shizuku.unbindUserService(ShizukuUserServiceArgs(ComponentName(context, ShizukuShellService::class.java.name)).daemon(false).tag("backup_service"), serviceConnection, true)
            }
        } catch (e: Exception) { /* Keep track context isolation clean */ }
        super.onDestroy()
    }
}
