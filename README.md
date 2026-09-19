# AppBack — No-Root Game Checkpoint & Cross-Device Sync

> **Freeze your game's state before a hard boss. Die? Load it back instantly.**
> And when you switch phones, carry your save with you — all **without rooting** your device.

AppBack is an Android utility that snapshots an app's *private* data (game saves, progress,
settings) and can sync it to another phone. It borrows elevated `shell` privileges through
[Shizuku](https://shizuku.rikka.app/) — no root, no unlocked bootloader, no PC needed after
first-time setup.

Think of it as a **save-state machine** (like on an emulator) for real Android games.

---

## Table of contents

- [What it does](#what-it-does)
- [What it can and cannot do (read this)](#what-it-can-and-cannot-do-read-this)
- [How it works in one line](#how-it-works-in-one-line)
- [Requirements](#requirements)
- [Setup — step by step](#setup--step-by-step)
  - [1. Install Shizuku](#1-install-shizuku)
  - [2. Start the Shizuku service](#2-start-the-shizuku-service)
  - [3. Build & install AppBack](#3-build--install-appback)
  - [4. First run](#4-first-run)
  - [5. (Optional) Enable cloud sync](#5-optional-enable-cloud-sync)
- [Using it](#using-it)
- [Troubleshooting](#troubleshooting)
- [Project layout](#project-layout)
- [For developers](#for-developers)
- [Responsible use](#responsible-use)

---

## What it does

| Feature | What it means | Status |
|---|---|---|
| **Freeze / Load (checkpoint)** | One-tap on-device snapshot of a game's data, and one-tap rollback. | ✅ Verified |
| **Cloud Upload / Pull** | Push a save to your Google account backup and pull it on another phone. | ✅ Verified |
| **Cross-device sync** | Play on Phone A → upload → pull on Phone B (same Google account). | ✅ Verified |
| **App list with names + icons** | Real app names and icons, fast scrolling. | ✅ |

---

## What it can and cannot do (read this)

Being honest up front, because Android's security model sets hard limits:

**✅ Can:**
- Snapshot and roll back the **real internal save data** of most apps (via the system backup
  engine) — **one checkpoint slot per app**. Re-freezing replaces it.
- Upload/pull that data to/from your Google account for cross-device transfer.

**❌ Cannot (without root):**
- Keep **multiple named checkpoints per app** ("Level 20", "Level 45"). The on-device backup
  transport holds exactly **one** slot per app, and the stored blob is system-owned — we
  can't copy it out to make our own versions. This is an OS limitation, not a bug.
- Read arbitrary app files directly (`/data/data/<pkg>` is sandboxed away from shell).

**Why:** everything that moves app data runs as the **shell (UID 2000)** identity via
Shizuku. Shell can *command* the Android backup manager (`bmgr`) to snapshot/restore, but it
**cannot read** other apps' private files or the backup blobs. True unlimited versioning
would require **root** (to `tar` the data directly). See
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full, tested reasoning.

---

## How it works in one line

```
Flutter UI (Dart) → MethodChannel → MainActivity.kt → Shizuku → bmgr (LocalTransport | Google cloud) → app data
```

The Android **backup manager** (`bmgr`) does the privileged read/write:
- **Freeze/Load** uses the on-device **LocalTransport** (rollback on the same phone).
- **Cloud Upload/Pull** uses Google's **GMS cloud transport** (cross-device, same account).

We never read protected data ourselves — we tell the *system* to do it.

---

## Requirements

- An Android device or emulator (Android 8.0+; behavior verified on Android 12+).
- The **Shizuku** app installed and running.
- For **building** from source: Flutter SDK (Dart `^3.10.7`) and Android SDK.
- For **cloud sync**: a Google account with Backup enabled on the device.

---

## Setup — step by step

### 1. Install Shizuku

Install Shizuku from the [Play Store](https://play.google.com/store/apps/details?id=moe.shizuku.privileged.api)
or [GitHub releases](https://github.com/RikkaApps/Shizuku/releases). It's a free, open-source
app that grants `shell`-level access to apps you approve — without root.

### 2. Start the Shizuku service

Shizuku must be *started* each time the device reboots. Pick the method that fits you:

**A. Wireless debugging (Android 11+, no PC needed)** — recommended
1. Enable **Developer options** (tap *Build number* 7× in Settings → About phone).
2. Settings → Developer options → turn on **Wireless debugging**.
3. Open Shizuku → **Start via Wireless debugging** → follow its pairing wizard.

**B. From a PC via ADB (any version)**
```bash
adb shell sh /storage/emulated/0/Android/data/moe.shizuku.privileged.api/start.sh
```
(Or use the "Start via computer" instructions inside the Shizuku app.)

When Shizuku shows **"Shizuku is running"**, you're set.

> ⚠️ On reboot, Shizuku stops. Re-run step 2 to restart it.

### 3. Build & install AppBack

```bash
flutter pub get                 # install Dart dependencies
flutter build apk --debug       # build the APK
flutter install                 # install to the connected device
# — or simply —
flutter run                     # build, install, and attach for logs
```

### 4. First run

1. Launch **AppBack**. The app bar reads **"AppBack · Checkpoints"**.
2. Tap **Connect & load apps**.
3. Approve the **Shizuku permission** prompt (first time only).
4. Your installed apps appear with names and icons.

### 5. (Optional) Enable cloud sync

Cloud Upload/Pull needs Google Backup configured **once**:
1. Settings → **System → Backup** → turn **Backup by Google One / Back up to Google Drive** ON.
2. Make sure a **backup account** is selected (your Google account).

AppBack flips the backup *setting* for you, but Android requires the *account* to be chosen
by you the first time — shell can't do that part.

---

## Using it

Tap any app in the list to open its **checkpoint panel**:

- **Freeze state** — snapshots the app's current data. (Re-freezing replaces the old one.)
- **Load** — force-stops the app and rolls its data back to the checkpoint.
- **Upload** — pushes the save to your Google account backup.
- **Pull** — pulls the latest cloud save down (great on a second phone).

**Typical "save scummer" flow:**
> About to fight a hard boss → open AppBack → **Freeze**. Die? → **Load** → try again.

**Cross-device flow:**
> Phone A: play, then **Upload**. Phone B (same Google account): install the game, open
> AppBack, **Pull**. Keep playing.

The app list shows each app's checkpoint status (e.g. *"Checkpoint · 2 hr ago"*).

---

## Troubleshooting

**"Could not connect to Shizuku" / bind times out**
AppBack shows an on-screen diagnostic (pingBinder, uid, permission, etc.). Common causes:
- **Shizuku not running** (`pingBinder: false`) → restart it (setup step 2).
- **Permission not granted** → reopen and approve the Shizuku prompt.
- **Connects but service never binds** (common on **Xiaomi/MIUI/HyperOS, Oppo, Vivo**):
  the ROM is killing Shizuku's spawned process. Fix:
  - Settings → Apps → **AppBack** → **Battery → No restrictions**.
  - Do the same for **Shizuku**.
  - Enable **Autostart** for AppBack (MIUI Security app).
  - In Developer options, disable **"MIUI optimization"** if present.

**"appback keeps stopping" right after install**
Usually a half-installed APK from an interrupted build. Fix:
```bash
adb uninstall com.threefourthdecade.appback
flutter install
```

**Freeze/Load reports success but the game didn't change**
The app may set `allowBackup="false"` (opts out of the backup framework), so its data isn't
captured. Not all apps participate.

---

## Project layout

```
lib/
  main.dart                         App entry point + root widget
  src/
    constants.dart                  Shared constants (MethodChannel name)
    models/app_info.dart            AppInfo: package + label + checkpoint time
    services/shizuku_manager.dart   Low-level MethodChannel wrapper
    controllers/shizuku_controller.dart  Connection lifecycle + backup/restore/cloud/list
    ui/home_page.dart               Main screen: app list, search, checkpoint sheet

android/app/src/main/
  AndroidManifest.xml               Perms (incl. QUERY_ALL_PACKAGES for names/icons)
  aidl/com/threefourthdecade/appback/IUserService.aidl   Cross-process contract
  kotlin/com/threefourthdecade/appback/
    MainActivity.kt                 Native bridge (Dart ↔ Shizuku), all method handlers
    ShizukuShellService.kt          Privileged worker (runs shell via sh -c)

docs/
  EXPLAINER.md                      Beginner-friendly deep dive (Shizuku/AIDL/bridge)
  ARCHITECTURE.md                   Living architecture doc + the tested "why"
```

---

## For developers

```bash
flutter pub get
flutter analyze          # static analysis (expect: No issues found)
flutter test             # widget smoke test
cd android && ./gradlew :app:compileDebugKotlin   # native compile check
```

- **MethodChannel** name lives in `lib/src/constants.dart` and must match `CHANNEL` in
  `MainActivity.kt`.
- Dependency direction is one-way: `ui → controllers → services → channel`.
- Package: `com.threefourthdecade.appback`. Shizuku API `dev.rikka.shizuku:api`/`:provider`.
- See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full method contract and design.

> Tip: if a build gets cancelled, a stale `R.jar` lock or half-installed APK can cause
> odd failures. Recover with `cd android && ./gradlew --stop`, then rebuild; and
> `adb uninstall com.threefourthdecade.appback` before reinstalling.

---

## Responsible use

AppBack reads and moves app data using elevated privileges. Use it only on **your own
devices and your own app data**. Respect each app's terms of service — some online games
treat save manipulation as a violation and may ban accounts. This tool is intended for
single-player save management and personal device migration.
