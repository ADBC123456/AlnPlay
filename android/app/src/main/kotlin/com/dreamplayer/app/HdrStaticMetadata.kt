package com.dreamplayer.app

/** HEVC SEI validation independent of decoder/window state. */
internal object HdrStaticMetadata {
    fun containsValidSei(buffer: ByteArray, start: Int, length: Int): Boolean {
        if (start < 0 || length < 2 || start > buffer.size - length) return false
        val header = buffer[start].toInt() and 0xff
        val type = (header shr 1) and 0x3f
        if (header and 0x80 != 0 || (type != 39 && type != 40) ||
            buffer[start + 1].toInt() and 7 == 0) return false

        // SEI lengths/field offsets refer to RBSP, before emulation prevention.
        val rbsp = ByteArray(length - 2)
        var count = 0
        var zeros = 0
        for (index in start + 2 until start + length) {
            val value = buffer[index].toInt() and 0xff
            if (zeros >= 2 && value == 3) {
                if (index + 1 >= start + length || (buffer[index + 1].toInt() and 0xff) > 3) return false
                zeros = 0
                continue
            }
            rbsp[count++] = buffer[index]
            zeros = if (value == 0) zeros + 1 else 0
        }
        var cursor = 0
        while (cursor + 1 < count) {
            var payloadType = 0
            while (cursor < count && (rbsp[cursor].toInt() and 0xff) == 255) {
                payloadType += 255
                cursor++
            }
            if (cursor >= count) return false
            payloadType += rbsp[cursor++].toInt() and 0xff
            var size = 0
            while (cursor < count && (rbsp[cursor].toInt() and 0xff) == 255) {
                size += 255
                cursor++
            }
            if (cursor >= count) return false
            size += rbsp[cursor++].toInt() and 0xff
            if (size > count - cursor) return false
            if (payloadType == 137 && size == 24) {
                val maximum = uint32(rbsp, cursor + 16)
                val minimum = uint32(rbsp, cursor + 20)
                if (maximum in 500_000L..100_000_000L && minimum < maximum) return true
            } else if (payloadType == 144 && size == 4) {
                val maximum = uint16(rbsp, cursor)
                val average = uint16(rbsp, cursor + 2)
                if (maximum in 10..10000 && average <= maximum) return true
            }
            cursor += size
        }
        return false
    }

    private fun uint16(bytes: ByteArray, at: Int): Int =
        ((bytes[at].toInt() and 0xff) shl 8) or (bytes[at + 1].toInt() and 0xff)

    private fun uint32(bytes: ByteArray, at: Int): Long =
        (0 until 4).fold(0L) { value, index ->
            (value shl 8) or (bytes[at + index].toLong() and 0xff)
        }
}
