package com.dreamplayer.app

import android.content.Context
import android.net.Uri
import androidx.media3.common.MimeTypes
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.Locale

/// Subtitle format detection and sibling auto-pairing, mirroring Just Player's
/// `SubtitleUtils` but expanded to every format the player supports.
///
/// Sideloaded sidecar files are matched to Media3 MIME types so they flow
/// through Media3's subtitle stack. Formats Media3 parses natively (SubRip,
/// SSA/ASS, WebVTT, TTML) map to the stock MIME constants; the formats Media3
/// lacks (SAMI, MicroDVD, MPL2, SubViewer) use the custom MIME types served by
/// [DreamSubtitleParserFactory].
object SubtitleFormats {

    const val MIME_SAMI = "application/x-sami"
    const val MIME_MICRODVD = "application/x-microdvd"
    const val MIME_MPL2 = "application/x-mpl2"

    private val VIDEO_EXTENSIONS = setOf(
        "mp4", "m4v", "mkv", "webm", "avi", "mov", "3gp", "3g2", "ts", "m2ts",
        "mts", "wmv", "flv", "mpg", "mpeg", "m2v", "vob", "divx", "ogv",
    )

    private val SUBTITLE_EXTENSIONS = setOf(
        "srt", "ass", "ssa", "vtt", "ttml", "dfxp", "xml", "smi", "sub", "mpl2",
    )

    /// Full extension -> MIME map. Anything unknown falls back to SubRip so
    /// odd-but-SRT-shaped files (e.g. mislabeled `.txt`) still play.
    fun mimeTypeFor(path: String): String {
        return when (extensionOf(path)) {
            "ass", "ssa" -> MimeTypes.TEXT_SSA
            "vtt" -> MimeTypes.TEXT_VTT
            "ttml", "dfxp", "xml" -> MimeTypes.APPLICATION_TTML
            "smi" -> MIME_SAMI
            "sub" -> MIME_MICRODVD
            "mpl2" -> MIME_MPL2
            else -> MimeTypes.APPLICATION_SUBRIP
        }
    }

    /// e.g. `Show.S01E01.eng.srt` -> `eng` (Just Player's rule: the 2..6-char
    /// segment between the last two dots is treated as a language tag).
    fun languageFromFileName(path: String): String? {
        val lower = path.lowercase(Locale.ROOT)
        val last = lower.lastIndexOf('.')
        if (last <= 0) return null
        var prev = last
        var i = last - 1
        while (i >= 0) {
            if (lower[i] == '.') {
                prev = i
                break
            }
            i--
        }
        val len = last - prev - 1
        return if (len in 2..6) lower.substring(prev + 1, last) else null
    }

    /// Display label, e.g. `Show.S01E01.eng` for `Show.S01E01.eng.srt`.
    fun labelFromFileName(path: String): String {
        val name = path.substringAfterLast('/')
        val base = name.substringBeforeLast('.')
        return if (base.isEmpty()) name else base
    }

    /// Whether [name] is a subtitle file we understand.
    fun isSubtitleFile(name: String): Boolean =
        extensionOf(name) in SUBTITLE_EXTENSIONS

    /// Whether [name] is a video file.
    fun isVideoFile(name: String): Boolean =
        extensionOf(name) in VIDEO_EXTENSIONS

    private fun extensionOf(path: String): String =
        path.substringAfterLast('.').lowercase(Locale.ROOT)

    /// All subtitle files in the video's folder that plausibly pair with it
    /// (Just Player's `findSubtitle` rule, expanded to keep every candidate):
    /// an exact filename-prefix match always wins; when the folder has exactly
    /// one video and one subtitle, that subtitle is the only candidate. The
    /// list is ordered best-match first so the caller can mark the first entry
    /// as the default-selected track.
    fun findSiblingSubtitles(videoPath: String): List<File> {
        val video = File(videoPath)
        val dir = video.parentFile ?: return emptyList()
        val files = dir.listFiles()?.toList() ?: return emptyList()
        val subtitles = files.filter { it.isFile && isSubtitleFile(it.name) }
        if (subtitles.isEmpty()) return emptyList()

        val videoBase = video.name.substringBeforeLast('.')
        val videoCount = files.count { it.isFile && isVideoFile(it.name) }

        // Single video + single subtitle in the folder: unambiguous pair.
        if (videoCount == 1 && subtitles.size == 1) {
            return subtitles
        }

        val lowerBase = videoBase.lowercase(Locale.ROOT)
        val prefixed = subtitles.filter { it.name.lowercase(Locale.ROOT).startsWith("$lowerBase.") }
        val ordered = prefixed.sortedBy { it.name.lowercase(Locale.ROOT) }
        if (ordered.isNotEmpty()) return ordered

        // No prefix match: still expose all subtitles so the picker can choose.
        return subtitles.sortedBy { it.name.lowercase(Locale.ROOT) }
    }

    /// Re-encodes a subtitle file to UTF-8 if it isn't already, writing the
    /// converted bytes to a cache file. Files that already decode as UTF-8 (or
    /// carry a UTF-8/UTF-16 BOM) pass through untouched, so no temp file is
    /// created for the common case.
    ///
    /// Media3's text parsers decode UTF-8 only; many `.srt` files on Android /
    /// NAS are CP1252/CP1251, which otherwise render as mojibake.
    fun toUtf8(context: Context, uri: Uri): Uri {
        val bytes = readAllBytes(context, uri) ?: return uri
        val charset = detectCharset(bytes)
        if (charset == StandardCharsets.UTF_8) return uri

        val text = String(bytes, charset)
        return try {
            val temp = CacheCleaner.writeSubtitle(context, text.toByteArray(StandardCharsets.UTF_8)) ?: return uri
            Uri.fromFile(temp)
        } catch (_: IOException) {
            uri
        }
    }

    /// Detects the charset of [bytes]: a UTF-16/UTF-8 BOM wins; otherwise a
    /// strict UTF-8 decode decides (valid -> UTF-8, invalid -> windows-1252).
    private fun detectCharset(bytes: ByteArray): Charset {
        if (bytes.size >= 2) {
            val first = bytes[0].toInt() and 0xff
            val second = bytes[1].toInt() and 0xff
            if (first == 0xfe && second == 0xff) return StandardCharsets.UTF_16BE
            if (first == 0xff && second == 0xfe) return StandardCharsets.UTF_16LE
        }
        if (bytes.size >= 3 &&
            (bytes[0].toInt() and 0xff) == 0xef &&
            (bytes[1].toInt() and 0xff) == 0xbb &&
            (bytes[2].toInt() and 0xff) == 0xbf
        ) {
            return StandardCharsets.UTF_8
        }
        val decoder = StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return try {
            decoder.decode(ByteBuffer.wrap(bytes))
            StandardCharsets.UTF_8
        } catch (_: CharacterCodingException) {
            cp1252
        }
    }

    private fun readAllBytes(context: Context, uri: Uri): ByteArray? {
        return try {
            context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } catch (_: Exception) {
            null
        }
    }

    /// Decodes subtitle bytes to a String, honoring a UTF-8 BOM (which
    /// `String(bytes, UTF_8)` would otherwise surface as an invisible U+FEFF).
    /// All sidecars are normalized to UTF-8 by [toUtf8] before reaching a
    /// parser, so no other charset handling is needed here.
    fun decodeToString(bytes: ByteArray, offset: Int, length: Int): String {
        var start = offset
        var end = offset + length
        if (length >= 3 &&
            (bytes[offset].toInt() and 0xff) == 0xef &&
            (bytes[offset + 1].toInt() and 0xff) == 0xbb &&
            (bytes[offset + 2].toInt() and 0xff) == 0xbf
        ) {
            start += 3
        }
        return String(bytes, start, end - start, StandardCharsets.UTF_8)
    }

    /// windows-1252, the de-facto charset for legacy `.srt` files on Android
    /// (Media3 has no constant for it).
    private val cp1252: Charset by lazy {
        try {
            Charset.forName("windows-1252")
        } catch (_: Exception) {
            StandardCharsets.ISO_8859_1
        }
    }
}
