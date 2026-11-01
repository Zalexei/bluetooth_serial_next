// Copyright 2026 Alexei Zalogin. Use of this source code is governed by the MIT license in the LICENSE file.
package io.github.zalexei.bluetooth_serial_next

import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream

/**
 * What a [PortSession] needs from an open port. The Bluetooth implementation
 * is [StreamSerialIo] over a socket's streams; tests use a fake.
 */
internal interface SerialIo {
    /** Size of the buffer [read] should get. */
    val readBufferSize: Int

    /** Blocks until data arrives. Returns -1 or throws once the link is gone. */
    fun read(buffer: ByteArray): Int

    /** [timeoutMs] 0 waits forever. */
    fun write(data: ByteArray, timeoutMs: Int)

    fun close()
}

/**
 * A connected RFCOMM socket. Its streams block and have no timeout, so
 * writes go out in chunks and the deadline is checked between them; a chunk
 * that is stuck still waits until the link moves again or is closed.
 */
internal class StreamSerialIo(
    private val input: InputStream,
    private val output: OutputStream,
    private val socket: Closeable,
    private val clock: () -> Long = System::nanoTime,
) : SerialIo {
    override val readBufferSize: Int get() = READ_BUFFER_BYTES

    override fun read(buffer: ByteArray): Int = input.read(buffer)

    override fun write(data: ByteArray, timeoutMs: Int) {
        val deadline = if (timeoutMs > 0) clock() + timeoutMs * 1_000_000L else Long.MAX_VALUE
        var offset = 0
        while (offset < data.size) {
            if (offset > 0 && clock() > deadline) {
                throw WriteTimeoutException(offset, "Wrote $offset of ${data.size} bytes in $timeoutMs ms")
            }
            val n = minOf(WRITE_CHUNK_BYTES, data.size - offset)
            output.write(data, offset, n)
            offset += n
        }
        output.flush()
    }

    override fun close() = socket.close()
}

// RFCOMM packets are at most about 1 KB; a few fit in one read.
private const val READ_BUFFER_BYTES = 8 * 1024
private const val WRITE_CHUNK_BYTES = 4 * 1024
