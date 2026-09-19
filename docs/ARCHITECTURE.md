# ARCHITECTURE

A living document describing how AppBack is structured and *why* it works the way it does.

> For a from-scratch conceptual explanation (what Shizuku / AIDL / the native bridge even
> are), read [`EXPLAINER.md`](EXPLAINER.md). This document assumes those basics and focuses
> on how the code is organized and the empirical findings that shaped it.

Last reviewed against code: Checkpoint UI + names/icons + on-device `bmgr` freeze/load +
cloud sync via GMS transport (cross-device verified).

---

## 1. High-level view

AppBack has two halves that talk over a single bridge:

```
┌─────────────────────────────┐          ┌──────────────────────────────────┐
│         Flutter (Dart)      │          │        Android native (Kotlin)   │
│                             │          │                                  │
│  UI  →  Controller  →  Manager  ───────▶  MainActivity  →  Shizuku        │
│                             │  Method  │        │                         │
│                             │  Channel │        ▼                         │
│                             │          │  ShizukuShellService (privileged)│
│                             │◀─────────│        │                         │
│          (results)          │          │        ▼  runs shell via sh -c   │
└─────────────────────────────┘          └──────────────────────────────────┘
```

- **Dart** owns the UI and all decision logic.
- **Kotlin** owns everything touching Android internals and Shizuku.
- The **MethodChannel** (name in `lib/src/constants.dart`) is the only link. It must match
  the `CHANNEL` string in `MainActivity.kt` exactly.

The core trick: the privileged `ShizukuShellService` runs as **shell (UID 2000)** and issues
`bmgr` commands. `bmgr` asks the **system** (backup-framework privilege) to read/write app
data. We never touch the protected files directly — that's what makes no-root possible.

---

## 2. The Dart side (`lib/`)

| Layer | File | Responsibility |
|---|---|---|
| Entry | `main.dart` | Boot app, theme, show `HomePage`. |
| UI | `src/ui/home_page.dart` | Main screen: app list, search, per-app checkpoint bottom sheet, lazy icons. |
| Orchestration | `src/controllers/shizuku_controller.dart` | Connection lifecycle + freeze/load/cloud/list workflows; returns `ActionResult`. |
| Transport | `src/services/shizuku_manager.dart` | Raw MethodChannel calls. Knows *how* to call native, not *when*. |
| Model | `src/models/app_info.dart` | `AppInfo` — package + human label + checkpoint timestamp. |
| Shared | `src/constants.dart` | Channel name and other cross-cutting constants. |

**Where new code goes:**
- Talks to the platform channel → `services/`
- Coordinates a multi-step workflow / business logic → `controllers/`
- A widget/screen → `ui/`
- A plain data model → `models/`

Dependency direction is one-way: `ui → controllers → services → channel`. The UI never calls
the channel directly.

### UI notes (performance + UX)
- **Lazy, cached icons:** `_AppIcon` fetches each app's icon (base64 PNG from native) only
  when its tile is built, and caches decoded bytes in a map owned by the screen state — so an
  icon is fetched/decoded at most once. This is what keeps long lists smooth.
- **Fixed row height** (`itemExtent: 72`) lets Flutter skip per-item measurement, the main
  source of scroll jank.
- **Checkpoint bottom sheet** (`_AppActionSheet`) is the "Save Scummer" control panel:
  Freeze / Load + Cloud Upload / Pull, with an honest "one checkpoint per app" note.

---

## 3. The native side (`android/app/src/main/`)

| File | Responsibility |
|---|---|
| `AndroidManifest.xml` | Declares `QUERY_ALL_PACKAGES` (needed so `PackageManager` can resolve *all* apps' labels/icons under Android 11+ package visibility) and the Shizuku provider. |
| `aidl/.../IUserService.aidl` | Cross-process contract: `runShellCommand(String)` and the Shizuku-required `destroy() = 16777114`. |
| `kotlin/.../MainActivity.kt` | The bridge. Registers the MethodChannel, manages the async `ServiceConnection`, and handles every method (see §4). Also resolves app labels/icons via `PackageManager`. |
| `kotlin/.../ShizukuShellService.kt` | Implements `IUserService.Stub`. Runs in Shizuku's privileged process, executes commands via `sh -c` (so `&&`, `;`, pipes, `$vars` work), merges stderr into stdout, reports exit code. |

`aidl = true` is set in `android/app/build.gradle.kts`; Shizuku via `dev.rikka.shizuku:api`
+ `:provider`.

---

## 4. The MethodChannel contract

| Method | Args | Returns | Purpose |
|---|---|---|---|
| `testNative` | — | `String` | Bridge sanity check (`echo bridge-ok`). |
| `requestShizukuPermission` | — | `bool` | Trigger Shizuku's permission dialog. |
| `bindService` | — | `bool` | Bind `ShizukuShellService`; **resolves only after `onServiceConnected`** or a timeout (see §5). |
| `runCommand` | `{command}` | `String` | Run a shell command with elevated privilege. |
| `listApps` | `{include_system}` | `String` | Newline-separated package names (`pm list packages`). |
| `getAppLabels` | `{packages: [String]}` | `String` | Batch `"<pkg>\t<label>"` lines via `PackageManager` (fast, no Shizuku). |
| `getAppIcon` | `{package_name}` | `String?` | Single app icon as base64 PNG (lazy, per-tile). |
| `listBackups` | — | `String` | `"<pkg>\t<epochSeconds>"` per app with a checkpoint marker (epoch = when it was set). |
| `backupAppData` | `{package_name}` | `String` | Freeze: `bmgr backupnow` (LocalTransport) + write marker on success. |
| `restoreAppData` | `{package_name}` | `String` | Load: `am force-stop` + `bmgr restore <token> <pkg>` (LocalTransport). |
| `cloudBackup` | `{package_name}` | `String` | Upload: select GMS transport + `bmgr backupnow`. |
| `cloudRestore` | `{package_name}` | `String` | Pull: select GMS transport + `bmgr restore <token> <pkg>`. |

When adding a native capability, update: the AIDL (if it crosses the privileged boundary),
`MainActivity.kt`, `ShizukuManager`, and this table.

Checkpoint markers live at `/data/local/tmp/appback_snapshots/<package>`; their file mtime is
the checkpoint time shown in the UI.

---

## 5. Binding to Shizuku (the async bind)

`Shizuku.bindUserService(args, connection)` is **asynchronous**: it returns immediately, and
the binder arrives later via `ServiceConnection.onServiceConnected` on the main thread.

`bindService` therefore **holds the Dart `MethodChannel.Result`** and resolves it inside
`onServiceConnected` (success) or via a **timeout** (error, with a `shizukuDiagnostics()`
snapshot attached: pingBinder, uid, version, permission, bound state). This replaced an
earlier fragile fixed `Future.delayed` sleep.

**Why the timeout matters:** on aggressive OEM ROMs (MIUI/HyperOS, Oppo, Vivo) the privileged
service process can be throttled or killed before it attaches, so the connection may never
fire. The diagnostics let the user see exactly what failed (see README troubleshooting).

> Field note: force-stopping the Shizuku *app* desyncs its server/app processes and causes
> `attachUserService "unable to find token"` + the service `System.exit(1)`. Recover by
> restarting the Shizuku server (its `libshizuku.so` starter), not force-stopping it.

---

## 6. Backup strategy — the empirical journey

Getting an app's **internal** data (`/data/data/<pkg>`) on a non-rooted device is the core
problem. Every approach was tested on-device (Android 12+):

| Approach | What we tried | Result |
|---|---|---|
| **Direct `tar`** | Shell copies `/data/data/<pkg>` | ❌ Shell (UID 2000) **cannot read** `/data/data`. Verified `Permission denied` on all backup paths too. |
| **`bu` / `adb backup`** | `bu backup <pkg>` → file | ❌ Only a **47-byte header, no data**. Android 12+ excludes app data from `adb backup` unless `android:debuggable=true` ([behavior change](https://developer.android.com/about/versions/12/behavior-changes-12#adb-backup-restrictions)). |
| **`run-as`** | `run-as <pkg>` to read data | ❌ "package not debuggable" for release apps. |
| **`bmgr` + LocalTransport** ✅ | `bmgr backupnow` / `bmgr restore` | ✅ **Captures & restores the real data.** Uses the *transport* path, not subject to the `adb backup` exclusion. Verified round-trip: score 8 → freeze → 18 → load → 8. |

**Key insight:** we never read the protected data. `bmgr` invokes the **system** to read
`/data/data` and write it back; the shell only issues the commands.

---

## 7. Multi-slot / versioning — tested and ruled out (no root)

We tried hard to support multiple named checkpoints per app without root. Every path was
tested on-device and failed:

| Idea | Test | Result |
|---|---|---|
| LocalTransport keeps history | `bmgr list sets` (local) | ❌ Always one set (`1 : Local disk image`), hardcoded. Re-backup overwrites. |
| Copy the LocalTransport blob to make slots | `ls`/`cp` on `/data/backup`, `/data/data/com.android.localtransport`, `/cache/backup`, `/data/system_ce/0/backup` | ❌ **Permission denied** for shell on every path. |
| Cloud keeps dated snapshots (token history) | `bmgr list sets` (GMS + D2D), backup again, compare | ❌ One token **per device**, not per time. New backup reuses the same token (matches Google docs: "only the most recent backup is stored"). |
| Multiple local transports as slots | `bmgr list transports -c` | ❌ Fixed system transports; one set each. |
| `Android/data` copy for named slots | `cp -r` out and back | ✅ **Works**, but `Android/data` is mostly cache/assets, **not the real save** for most modern games — so it doesn't solve the actual goal. |

**Conclusion:** on-device internal-data backup is fundamentally **one slot per app**. True
unlimited named checkpoints of *real* saves require **root** (`tar /data/data/<pkg>` directly,
then keep N archives we own). This is the planned root-optional path.

---

## 8. Cross-device sync — solved via Google's cloud transport (verified)

- **Freeze/Load (on-device):** `bmgr` + LocalTransport. Same-phone snapshot/rollback.
- **Cloud Upload/Pull:** the **GMS cloud transport**
  (`com.google.android.gms/.backup.BackupTransportService`):
  - `cloudBackup` → select GMS → `bmgr backupnow <pkg>` → uploads to the user's Google
    account backup (verified ~3 MB, "result: Success").
  - `cloudRestore` → select GMS → read token from `bmgr list sets` → force-stop →
    `bmgr restore <token> <pkg>` (verified `restoreFinished: 0`, on-demand).
- **Cross-device (verified):** Phone A uploads, Phone B (same Google account) pulls. Tokens
  identify *devices*, so Phone B can restore Phone A's dataset.

**Requirements / caveats:**
- Google Backup **ON** with a **backup account** set (Settings → System → Backup). We enable
  the setting via shell; the account must be chosen once by the user.
- **25 MB/app** cloud limit; **one backup set per app** (newest overwrites) — no cloud history.
- Only apps with `ALLOW_BACKUP` participate.
- The data is end-to-end encrypted with the device lock secret and stored in a hidden,
  account-private Drive folder — not user-browsable or editable.

---

## 9. Key runtime sequence (Freeze)

```
HomePage → _AppActionSheet "Freeze"
  → ShizukuController.backup(pkg)
      → ensureConnected()                 [permission + async bind (§5)]
      → ShizukuManager.backupApp(pkg)      [channel: backupAppData]
          → MainActivity (background thread)
              → runShellCommand(
                  "bmgr enable true; bmgr transport …/.LocalTransport;
                   bmgr backupnow <pkg>; <write marker on Success>")
                  → ShizukuShellService runs via sh -c        [AIDL boundary]
                  → system reads /data/data → LocalTransport
              → success if output contains "result: Success"
          ← success message or BACKUP_FAILED
      ← ActionResult(success, message)
  → SnackBar + refresh (shows "Checkpoint · just now")
```

Load mirrors this: read token from `bmgr list sets`, `am force-stop <pkg>`, then
`bmgr restore <token> <pkg>`.

---

## 10. Known issues & tech debt

- **One checkpoint per app** (see §7) — hard OS limit without root. Root `tar` path planned.
- **Restore token selection:** we use the first token from `bmgr list sets`. With multiple
  sets (e.g. several devices) this could pick the wrong one; should match by device/contents.
- **`onDestroy` unbind:** the `unbindUserService` call is still commented out; leaked
  connections should be cleaned up.
- **OEM throttling:** MIUI/HyperOS etc. may kill the privileged service before it binds; we
  surface diagnostics but can't fully fix it from inside the app (user must whitelist).
- **`allowBackup=false` apps** can't be captured.

---

## 11. Roadmap

- [x] Flutter ↔ native bridge (MethodChannel)
- [x] Shizuku permission + async user-service bind (with on-screen diagnostics)
- [x] On-device Freeze/Load via `bmgr` (verified)
- [x] Cloud Upload/Pull via GMS transport (verified)
- [x] Cross-device sync verified (same Google account)
- [x] App names + icons + smooth scrolling
- [x] Checkpoint timestamps + "Save Scummer" UI
- [ ] Root detection + `tar`-based **true multi-slot** for rooted devices
- [ ] Show app list before Shizuku connects (names/icons need no Shizuku)
- [ ] Batch freeze/load across multiple apps
- [ ] In-app Google-Backup-account health check

---

## 12. How to update this doc

- Changed the MethodChannel API? Update §4.
- Added a Dart file? Slot it into §2 and keep the dependency direction.
- Added native capability? Update §3 and §4.
- Discovered a new platform limit? Record the *test* and result in §6/§7 so we don't re-chase it.
- Update the "Last reviewed against code" line at the top when you do a pass.
