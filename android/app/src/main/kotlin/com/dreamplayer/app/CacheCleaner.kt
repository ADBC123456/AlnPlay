package com.dreamplayer.app

import android.content.Context
import io.flutter.plugin.common.MethodChannel
import java.io.File
import android.os.Handler
import android.os.Looper

/// Coordinates the bounded, regenerable AlnPlay cache. User files and the
/// application-support library are intentionally outside this policy.
class CacheCleaner(private val context: Context) {

    companion object {
        @Volatile var limitBytes: Long = 5L * 1024 * 1024 * 1024
        @Volatile var playbackActive: Boolean = false
        private var pendingReservedBytes: Long = 0
        private val directories = setOf("danmaku", "cover_art", "sidecar_subs", "opensubs", "native_subtitles")

        private fun managedFiles(context: Context): List<File> = context.cacheDir.listFiles()
            ?.flatMap { entry ->
                when {
                    entry.isDirectory && entry.name in directories -> entry.walkTopDown()
                        .onEnter { it.canonicalPath == it.absolutePath }.filter { it.isFile && it.canonicalPath == it.absolutePath }.toList()
                    entry.isFile && (entry.name.matches(Regex("dreamplayer_sub_\\d+\\.utf8")) ||
                        entry.name.matches(Regex("picked_sub_\\d+\\.[a-zA-Z0-9]+"))) -> listOf(entry)
                    else -> emptyList()
                }
            } ?: emptyList()

        /// Native decoder callbacks cannot synchronously call Dart. They only
        /// create bounded, active subtitle files; Dart reconciles total usage.
        @Synchronized fun reserveWrite(context: Context, bytes: Long): Boolean {
            if (bytes < 0 || (limitBytes > 0 && bytes > limitBytes)) return false
            val used = managedFiles(context).sumOf { it.length() }
            if (limitBytes > 0 && used + pendingReservedBytes + bytes > limitBytes) return false
            pendingReservedBytes += bytes
            return true
        }

        @Synchronized fun releaseWrite(bytes: Long) {
            pendingReservedBytes = (pendingReservedBytes - bytes.coerceAtLeast(0)).coerceAtLeast(0)
        }

        @Synchronized fun setPolicy(limit: Long, active: Boolean) {
            limitBytes = limit
            playbackActive = active
        }

        @Synchronized fun writeSubtitle(
            context: Context,
            bytes: ByteArray,
            suffix: String = ".utf8",
        ): File? {
            if (limitBytes > 0 && bytes.size.toLong() > limitBytes) return null
            val files = managedFiles(context)
            // Dart owns eviction. Refuse optional native writes when the
            // existing managed bytes plus this file exceed the shared policy.
            if (limitBytes > 0 && files.sumOf { it.length() } + pendingReservedBytes + bytes.size > limitBytes) return null
            val directory = File(context.cacheDir, "native_subtitles").apply { mkdirs() }
            val safeSuffix = suffix.takeIf { it.matches(Regex("\\.[a-zA-Z0-9]{1,8}")) } ?: ".utf8"
            val temporary = File.createTempFile("subtitle_", safeSuffix, directory)
            return try { temporary.writeBytes(bytes); temporary } catch (_: Exception) {
                temporary.delete(); null
            }
        }
    }

    fun configure(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "policy") {
                setPolicy(
                    call.argument<Number>("limitBytes")?.toLong() ?: limitBytes,
                    call.argument<Boolean>("playbackActive") ?: false,
                )
                result.success(null)
                return@setMethodCallHandler
            }
            if (call.method == "reserveWrite") {
                val bytes = call.argument<Number>("bytes")?.toLong() ?: -1
                result.success(reserveWrite(bytes))
                return@setMethodCallHandler
            }
            if (call.method == "releaseWrite") {
                releaseWrite(call.argument<Number>("bytes")?.toLong() ?: 0)
                result.success(null)
                return@setMethodCallHandler
            }
            // Retained for old clients. Clear is bounded and respects playback;
            // new clients use the Dart quota manager for all eviction.
            Thread {
            when (call.method) {
                "size" -> { val value = cacheSizeBytes(); Handler(Looper.getMainLooper()).post { result.success(value) } }
                "clear" -> { val value = clearCacheBytes(); Handler(Looper.getMainLooper()).post { result.success(value) } }
                else -> Handler(Looper.getMainLooper()).post { result.notImplemented() }
            }
            }.start()
        }
    }

    private fun cacheSizeBytes(): Long =
        managedFiles(context).sumOf { it.length() }

    private fun reserveWrite(bytes: Long): Boolean =
        Companion.reserveWrite(context, bytes)

    private fun releaseWrite(bytes: Long) = Companion.releaseWrite(bytes)

    private fun clearCacheBytes(): Long {
        var freed = 0L
        if (playbackActive) return freed
        for (file in managedFiles(context)) {
            val size = file.length()
            if (file.delete()) freed += size
        }
        return freed
    }
}
