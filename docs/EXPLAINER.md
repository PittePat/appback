# EXPLAINER — How this whole thing works (beginner edition)

This is the "explain it to a human" doc. In plain language: **what the app does**,
**why it's genuinely hard**, **how we pulled it off without root**, and **what every piece
of code does**. No prior knowledge of Kotlin, AIDL, or Shizuku needed. Read top to bottom.

---

## 1. What the app actually is (say this first)

**AppBack is a "save-state machine" for Android games — no root required.**

You know how emulators let you *save state* before a hard boss and *load state* if you die?
AppBack does that for **real Android apps**:

- **Freeze** — snapshot a game's current save.
- **Load** — instantly roll it back to that snapshot.
- **Cloud Upload / Pull** — send that save to your Google account and pull it on **another
  phone** (play on Phone A, continue on Phone B).

The headline: doing this on **internal** app data **without rooting the phone** is the
hard, interesting part. Most backup apps either only copy the app file (the APK — boring)
or require root. We don't.

---

## 2. The core problem: the Android sandbox

Android puts every app in a **sandbox** — imagine each app living in its own locked room.
App A cannot walk into App B's room and read its files. That's a security feature; it stops
a malicious app from stealing your banking data.

But *we* want to read/write another app's save data (to back it up and restore it). So we
need a key to the locked rooms. There are only three real keys:

1. **Root** — full control, but requires modifying/unlocking the phone. Most users can't or
   won't.
2. **Shizuku** — a clever middle-ground that gives near-root power *without* rooting.
   **This is what we use.**
3. **Official Android backup APIs** — limited and apps can opt out.

Where does a game keep its save? Two places:

| Location | Example | Can we read it without root? |
|---|---|---|
| **Internal** | `/data/data/<package>` | ❌ No — sandboxed. This is where the *real* save usually lives. |
| **External** | `/storage/emulated/0/Android/data/<package>` | ✅ Yes — but it's mostly cache/downloaded assets, not the real save. |

So the valuable data (internal) is exactly the data we *can't* directly touch. That tension
is the whole story.

---

## 3. What is Shizuku? (the key idea)

Android has a built-in high-power account called **`shell`** — the same identity that runs
when you plug your phone into a computer for debugging (ADB). It can do more than a normal
app.

**Shizuku** is a separate app the user installs. Its job:

1. The user starts Shizuku once (via wireless debugging or a PC).
2. Shizuku keeps a running process that holds the **`shell`** power.
3. Other apps (like ours) can **ask Shizuku** to run privileged work *on their behalf*.

```
Our app ──"please run this command"──► Shizuku (has shell power) ──► runs it ──► sends back the result
```

So we never hold the master key ourselves — we politely ask the trusted Shizuku middleman
to do privileged things for us. (The user approves our app in Shizuku with a one-time popup.)

**Important honesty:** even `shell` power is NOT root. `shell` still **cannot read**
`/data/data/<pkg>` directly. So Shizuku alone doesn't crack the sandbox — which is why the
next idea matters.

---

## 4. The actual trick: don't read the data — tell the SYSTEM to

Here's the clever bit that makes no-root work.

Android has a built-in **Backup Manager** (`bmgr`) — the thing that backs up your apps to
Google when you set up a new phone. `bmgr` runs as the **system**, which *is* allowed into
every app's locked room.

We can't read the save. But we *can* use our `shell` power to **command `bmgr`** to do it:

- **Freeze** = `bmgr backupnow <package>` → the system reads the app's real data and stores it.
- **Load** = `bmgr restore <token> <package>` → the system writes it back.

So the flow is: **we (shell) give the order → the system (bmgr) does the privileged
read/write.** We're the manager telling the security guard to open the door; we never hold
the key. That's how we snapshot *internal* save data without root.

---

## 5. What is AIDL? (how two programs talk)

A subtlety: our app and the Shizuku-powered worker are **two separate programs** in separate
memory. They can't just call each other's functions.

Android's way for two processes to talk is called **Binder**, and the way you *describe* that
conversation is a file format called **AIDL** (Android Interface Definition Language).

Think of AIDL as a **contract / menu** — "here are the functions you can call across the
boundary, and their types." Ours (`IUserService.aidl`) says:

```aidl
interface IUserService {
    void destroy() = 16777114;                     // Shizuku requires this exact number to shut the worker down
    String runShellCommand(String command) = 1;    // send a command, get its text output back
}
```

At build time, Android **auto-generates** a Kotlin/Java class from this file that handles all
the messy "pack the data, send it across processes, unpack it" work. You just call
`runShellCommand(...)` and it feels like a normal call — but it's crossing a process boundary.

Two generated pieces to know:
- **`IUserService.Stub`** — the *server* side; the privileged worker `extends` it.
- **`IUserService.Stub.asInterface(binder)`** — the *client* side; turns the raw connection
  into something we can call methods on.

---

## 6. Why Kotlin at all?

Flutter's UI is **Dart**. But Dart can't talk to Shizuku/Binder directly — those are
Android-world things. So we add a thin layer of native **Kotlin** as the **bridge**:

```
Dart says "freeze this app" → Kotlin receives it → Kotlin asks Shizuku to run bmgr → Kotlin sends the result back to Dart
```

The pipe between Dart and Kotlin is a **MethodChannel**. Both sides agree on one name string
(`com.threefourthdecade.appback/channel`) — like tuning two radios to the same frequency.

---

## 7. Walking through the actual files

### Native (Android / Kotlin)

**`IUserService.aidl`** — the contract from §5. Building the app turns it into generated code.

**`ShizukuShellService.kt`** — the **privileged worker**. Runs *inside the Shizuku process*
(with `shell` power) and implements the contract:
```kotlin
class ShizukuShellService : IUserService.Stub {
    override fun runShellCommand(command: String?): String? {
        // Runs the command through: sh -c "<command>"
        // so &&, ;, pipes and $variables all work; merges error output; returns the text.
    }
}
```

**`MainActivity.kt`** — the **bridge / traffic controller**. It:
1. Sets up the MethodChannel.
2. Handles the calls Dart makes, e.g.:
   - `requestShizukuPermission` → shows Shizuku's permission popup.
   - `bindService` → asks Shizuku to launch our worker and connect us to it.
   - `backupAppData` / `restoreAppData` → the **Freeze / Load** (run `bmgr` locally).
   - `cloudBackup` / `cloudRestore` → **Upload / Pull** (run `bmgr` with Google's transport).
   - `listApps`, `getAppLabels`, `getAppIcon` → build the app list with real names & icons.
3. Manages the connection to the worker (`onServiceConnected`).

### Flutter (Dart)

- **`main.dart`** — boots the app, shows the home screen.
- **`ui/home_page.dart`** — the one screen: searchable app list (names + icons), and a
  per-app **checkpoint sheet** with Freeze / Load / Upload / Pull.
- **`services/shizuku_manager.dart`** — the low-level Dart wrapper: one method per native
  call. Knows *how* to call native.
- **`controllers/shizuku_controller.dart`** — the orchestration: connect to Shizuku, then
  run freeze/load/cloud/list. Knows *when* to do things.
- **`models/app_info.dart`** — a small data object: an app's package, human name, and when
  its checkpoint was set.

Rule: the UI never calls native directly. It goes `ui → controller → manager → channel`.

---

## 8. The full journey of ONE action (Freeze)

When you tap **Freeze** on a game:

```
[Dart] home_page → controller.backup(pkg)
   │
   ├─► ensureConnected()                     (permission + connect to the worker)
   │
   └─► manager.backupApp(pkg)
          └─► MethodChannel "backupAppData"
                 └─► [Kotlin] MainActivity (background thread)
                        └─► worker.runShellCommand(
                              "bmgr transport …LocalTransport; bmgr backupnow <pkg>")
                                 └─► [worker, shell power] runs it via sh -c   ← crosses the process boundary (AIDL/Binder)
                                        └─► the SYSTEM (bmgr) reads the app's real data and stores it
                                 ◄── returns "Backup finished: Success"
                        ◄── Kotlin returns the result to Dart
          ◄── ActionResult(success)
   ◄── UI shows "Checkpoint · just now"
```

That relay — Dart → Kotlin → AIDL → shell worker → system `bmgr` → back — is the entire
engine. **Load** is the same in reverse (`bmgr restore`). **Cloud** is the same but selects
Google's transport instead of the local one.

---

## 9. The actual limits 

We tested every trick. These walls are real, not laziness:

- **One checkpoint per app (on-device).** The local backup transport keeps exactly **one**
  slot per app — a new Freeze replaces the old one. And its stored blob is system-owned, so
  we can't copy it out to make our own "Version 1, Version 2." True multi-slot needs root.
- **Cloud is latest-only.** Google keeps one backup per app (newest wins) — it's not a time
  machine. But it *is* per-device, which is exactly what makes cross-device sync work.
- **External data (`Android/data`) is readable but usually just cache/assets**, not the real
  save — so copying it isn't a substitute.
- **Everything runs as `shell`, never root**, so we command the system rather than touching
  files. The moment you have **root**, all these limits lift (you can `tar` the data
  directly and keep unlimited named saves).

Being upfront about this is the point: it's not "a shitty backup app," it's a genuinely
clever **no-root save-state tool** operating right at the edge of what Android allows.

---

## 10. Glossary (quick reference)

- **Sandbox** — Android's rule that each app is isolated and can't read others' files.
- **Root** — full admin control of the phone; powerful but requires modifying the device.
- **Shizuku** — an app that holds `shell`-level power and lets approved apps borrow it.
- **`shell` / ADB user** — a built-in account with more power than normal apps, but still
  not root (can't read `/data/data`).
- **`bmgr`** — Android's Backup Manager; runs as the *system* and can read/write app data.
  We command it; it does the privileged work.
- **LocalTransport** — the on-device backup destination (one slot). Used for Freeze/Load.
- **GMS / cloud transport** — Google's backup destination. Used for Upload/Pull (cross-device).
- **Binder** — Android's system for letting two separate processes communicate.
- **AIDL** — the file format describing the Binder "contract" (which functions cross processes).
- **Stub** — the auto-generated server-side base class from an AIDL interface.
- **MethodChannel** — Flutter's pipe between Dart and native code.
- **Package name** — an app's unique ID, e.g. `com.rectfy.birdybird`.
- **Token** — the ID `bmgr` gives a backup set; identifies *a device's* backup, not a point in time.
