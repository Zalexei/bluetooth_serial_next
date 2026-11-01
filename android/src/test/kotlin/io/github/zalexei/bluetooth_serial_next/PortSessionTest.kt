package io.github.zalexei.bluetooth_serial_next

import java.io.ByteArrayInputStream
import java.io.Closeable
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** A link whose reads the test feeds; close() makes the blocked read fail like a socket does. */
private class FakeSerialIo : SerialIo {
    private val incoming = LinkedBlockingQueue<Any>()
    val written = mutableListOf<ByteArray>()
    var closeCount = 0

    fun feed(vararg bytes: Int) = incoming.put(ByteArray(bytes.size) { bytes[it].toByte() })

    fun end() = incoming.put(-1)

    fun fail(error: Throwable) = incoming.put(error)

    override val readBufferSize = 16

    override fun read(buffer: ByteArray): Int = when (val next = incoming.take()) {
        is Throwable -> throw next
        is Int -> next
        is ByteArray -> next.copyInto(buffer).let { next.size }
        else -> error("unreachable")
    }

    override fun write(data: ByteArray, timeoutMs: Int) {
        written += data
    }

    override fun close() {
        closeCount++
        incoming.put(IOException("socket closed"))
    }
}

/** Runs posted tasks on the test thread when it asks. */
private class Recorder : PortSession.Listener {
    val tasks = LinkedBlockingQueue<Runnable>()
    val data = mutableListOf<Int>()
    val closes = mutableListOf<FlutterError?>()

    fun post(task: Runnable) = tasks.put(task)

    /** Runs tasks until [done] or a timeout. */
    fun runUntil(done: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (!done()) {
            val task = tasks.poll(50, TimeUnit.MILLISECONDS)
            task?.run()
            check(System.nanoTime() < deadline) { "timed out" }
        }
    }

    override fun onData(session: PortSession, data: ByteArray) {
        data.forEach { this.data += it.toInt() }
    }

    override fun onClosed(session: PortSession, error: FlutterError?) {
        closes += error
    }
}

class PortSessionTest {
    private val io = FakeSerialIo()
    private val recorder = Recorder()
    private var adapterOn = true
    private val session = PortSession(
        id = 7,
        address = "94:3C:C6:8C:2F:B6",
        io = io,
        post = recorder::post,
        readFailure = { if (adapterOn) SerialErrors.disconnected() else SerialErrors.adapterOff() },
        listener = recorder,
    )

    @Test
    fun `delivers what it reads`() {
        session.start()
        io.feed(1, 2)
        io.feed(3)

        recorder.runUntil { recorder.data.size == 3 }
        assertEquals(listOf(1, 2, 3), recorder.data)
    }

    @Test
    fun `a lost link closes the port as disconnected`() {
        session.start()
        io.feed(9)
        io.fail(IOException("bt socket closed, read return: -1"))

        recorder.runUntil { recorder.closes.isNotEmpty() }
        assertEquals(listOf(9), recorder.data, "data before the loss still arrives")
        assertEquals(SerialErrors.DISCONNECTED, recorder.closes.single()?.code)
        assertTrue(session.isClosed)
    }

    @Test
    fun `the end of the stream counts as a lost link`() {
        session.start()
        io.end()

        recorder.runUntil { recorder.closes.isNotEmpty() }
        assertEquals(SerialErrors.DISCONNECTED, recorder.closes.single()?.code)
    }

    @Test
    fun `Bluetooth turned off closes it as adapter off`() {
        adapterOn = false
        session.start()
        io.fail(IOException("socket closed"))

        recorder.runUntil { recorder.closes.isNotEmpty() }
        assertEquals(SerialErrors.ADAPTER_OFF, recorder.closes.single()?.code)
    }

    @Test
    fun `a requested close happens once and without an error`() {
        session.start()

        assertTrue(session.close())
        assertFalse(session.close())
        recorder.runUntil { recorder.closes.isNotEmpty() }
        Thread.sleep(100)
        recorder.tasks.poll()?.run()

        assertEquals(1, io.closeCount)
        assertEquals(listOf<FlutterError?>(null), recorder.closes)
    }

    @Test
    fun `writes go out in order`() {
        val results = mutableListOf<Result<Unit>>()
        session.write(byteArrayOf(1), 1000) { results += it }
        session.write(byteArrayOf(2, 3), 1000) { results += it }

        recorder.runUntil { results.size == 2 }
        assertTrue(results.all { it.isSuccess })
        assertEquals(listOf(listOf<Byte>(1), listOf<Byte>(2, 3)), io.written.map { it.toList() })
    }

    @Test
    fun `a write after the close fails with the reason`() {
        session.close(SerialErrors.disconnected())
        val results = mutableListOf<Result<Unit>>()
        session.write(byteArrayOf(1), 1000) { results += it }

        recorder.runUntil { results.isNotEmpty() }
        assertEquals(SerialErrors.DISCONNECTED, (results.single().exceptionOrNull() as FlutterError).code)
    }
}

class StreamSerialIoTest {
    private class SlowOutput(private val nanosPerWrite: Long, private val now: LongArray) : OutputStream() {
        val chunks = mutableListOf<Int>()
        override fun write(b: Int) = error("unused")
        override fun write(b: ByteArray, off: Int, len: Int) {
            chunks += len
            now[0] += nanosPerWrite
        }
    }

    @Test
    fun `writes in chunks of 4 KB`() {
        val now = longArrayOf(0)
        val output = SlowOutput(0, now)
        val io = StreamSerialIo(ByteArrayInputStream(ByteArray(0)), output, Closeable {}, clock = { now[0] })

        io.write(ByteArray(10_000), 1000)

        assertEquals(listOf(4096, 4096, 1808), output.chunks)
    }

    @Test
    fun `stops between chunks when the time is up`() {
        val now = longArrayOf(0)
        // 40 ms per chunk, 100 ms allowed: three chunks go out.
        val output = SlowOutput(40_000_000, now)
        val io = StreamSerialIo(ByteArrayInputStream(ByteArray(0)), output, Closeable {}, clock = { now[0] })

        val e = assertFailsWith<WriteTimeoutException> { io.write(ByteArray(40_000), 100) }

        assertEquals(3 * 4096, e.bytesWritten)
        val error = SerialErrors.from(e)
        assertEquals(SerialErrors.TIMEOUT, error.code)
        assertEquals(3 * 4096L, error.details)
    }

    @Test
    fun `timeout 0 waits for everything`() {
        val now = longArrayOf(0)
        val output = SlowOutput(1_000_000_000, now)
        val io = StreamSerialIo(ByteArrayInputStream(ByteArray(0)), output, Closeable {}, clock = { now[0] })

        io.write(ByteArray(20_000), 0)

        assertEquals(5, output.chunks.size)
    }

    @Test
    fun `maps Android's exceptions`() {
        assertEquals(SerialErrors.PERMISSION_DENIED, SerialErrors.from(SecurityException("no BLUETOOTH_CONNECT")).code)
        assertEquals(SerialErrors.IO_ERROR, SerialErrors.from(IOException("boom")).code)
        assertEquals(SerialErrors.INVALID_ARGUMENT, SerialErrors.from(IllegalArgumentException("bad")).code)
        assertNull(SerialErrors.from(IOException("boom")).details)
        assertContentEquals(byteArrayOf(), ByteArray(0))
    }
}
