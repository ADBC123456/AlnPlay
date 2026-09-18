package com.dreamplayer.app

private fun sei(type: Int, payload: ByteArray): ByteArray {
    val rbsp = byteArrayOf(type.toByte(), payload.size.toByte()) + payload + byteArrayOf(0x80.toByte())
    val escaped = ArrayList<Byte>()
    var zeros = 0
    for (byte in rbsp) {
        if (zeros >= 2 && (byte.toInt() and 0xff) <= 3) {
            escaped.add(3)
            zeros = 0
        }
        escaped.add(byte)
        zeros = if (byte == 0.toByte()) zeros + 1 else 0
    }
    return byteArrayOf(78, 1) + escaped.toByteArray()
}

private fun checkSei(bytes: ByteArray) = HdrStaticMetadata.containsValidSei(bytes, 0, bytes.size)

fun main() {
    check(!checkSei(sei(137, ByteArray(24))))
    check(!checkSei(sei(144, ByteArray(4))))
    val mastering = ByteArray(24)
    fun put32(at: Int, value: Long) {
        for (i in 0..3) mastering[at + i] = (value shr ((3 - i) * 8)).toByte()
    }
    put32(16, 10_000_000)
    put32(20, 1000)
    check(checkSei(sei(137, mastering)))
    put32(20, 0xffffffffL)
    check(!checkSei(sei(137, mastering)))
    check(checkSei(sei(144, byteArrayOf(3, 0xe8.toByte(), 1, 0x90.toByte()))))
    check(!checkSei(sei(144, byteArrayOf(0, 100, 0, 101))))
    check(!checkSei(byteArrayOf(78, 1, 137.toByte(), 24, 0)))
    check(!checkSei(byteArrayOf(78, 0, 144.toByte(), 4, 3, 0xe8.toByte(), 0, 1)))
    check(!HdrStaticMetadata.containsValidSei(byteArrayOf(78, 1), -1, 2))
    println("HDR static metadata: 9 checks passed")
}
