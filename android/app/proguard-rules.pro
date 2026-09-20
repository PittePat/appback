# --- AppBack ProGuard / R8 rules ---
#
# Why this file exists:
# Shizuku launches our privileged service BY CLASS NAME via reflection
# (Class.newInstance). R8 in release builds renames/obfuscates classes, so
# `ShizukuShellService` became `C.n` and Shizuku could not instantiate it
# (java.lang.InstantiationException). These keep rules preserve the exact names
# and members that Shizuku and the AIDL/Binder machinery rely on.

# Keep our privileged user-service class and its constructors intact.
-keep class com.threefourthdecade.appback.ShizukuShellService { *; }

# Keep the generated AIDL interface + its Stub/Proxy (Binder needs these names).
-keep class com.threefourthdecade.appback.IUserService { *; }
-keep class com.threefourthdecade.appback.IUserService$* { *; }

# Keep the whole Shizuku API/provider (it uses reflection internally too).
-keep class rikka.shizuku.** { *; }
-keep interface rikka.shizuku.** { *; }
-dontwarn rikka.shizuku.**

# General: keep any AIDL Stub classes' Binder machinery.
-keepclassmembers class * extends android.os.Binder { *; }
