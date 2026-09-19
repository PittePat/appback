package com.threefourthdecade.appback

import android.os.IBinder

// 1. Changed class name to match ShizukuShellService.kt
class ShizukuShellService : IUserService.Stub {
    
    constructor() : super()

    override fun destroy() {
        System.exit(0)
    }

    // 2. Added '?' to command and String return type to match AIDL compiler nullability rules
    override fun runShellCommand(command: String?): String? {
        if (command.isNullOrBlank()) return "Empty command"

        return try {
            // Run through a real shell so operators like &&, ||, |, ; and
            // variable expansion actually work. Runtime.exec(String) does NOT
            // do this — it just splits on spaces and runs a single program,
            // which silently drops everything after the first "&&".
            val process = Runtime.getRuntime().exec(arrayOf("sh", "-c", command))

            // Merge stderr into stdout so command failures are visible instead
            // of vanishing. Read on a separate thread to avoid buffer deadlocks.
            val stdout = StringBuilder()
            val stderr = StringBuilder()

            val errThread = Thread {
                process.errorStream.bufferedReader().useLines { lines ->
                    lines.forEach { stderr.append(it).append("\n") }
                }
            }
            errThread.start()

            process.inputStream.bufferedReader().useLines { lines ->
                lines.forEach { stdout.append(it).append("\n") }
            }

            errThread.join()
            val exitCode = process.waitFor()

            buildString {
                append(stdout)
                if (stderr.isNotBlank()) {
                    append("\n--- stderr ---\n")
                    append(stderr)
                }
                append("\n[exit code: ")
                append(exitCode)
                append("]")
            }
        } catch (e: Exception) {
            "Error: ${e.message}"
        }
    }
}
