package io.github.zalexei.bluetooth_serial_next

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/** A socket whose connect() does what the test says. */
private class FakeSocket(private val behavior: () -> Unit) : RfcommSocket {
    private val closedLatch = CountDownLatch(1)
    var closed = false

    override fun connect() = behavior()

    /** For a connect that hangs until the socket is closed, like Android's. */
    fun hangUntilClosed() {
        closedLatch.await(10, TimeUnit.SECONDS)
        throw IOException("socket closed")
    }

    override val inputStream = ByteArrayInputStream(ByteArray(0))
    override val outputStream = ByteArrayOutputStream()

    override fun close() {
        closed = true
        closedLatch.countDown()
    }
}

class ConnectorTest {
    private val watchdog = Executors.newSingleThreadScheduledExecutor()
    private val connector = Connector(watchdog, pauseMs = 1)

    @AfterTest
    fun tearDown() {
        watchdog.shutdownNow()
    }

    @Test
    fun `auto tries secure and then insecure`() {
        assertEquals(
            listOf(Attempt(true, null), Attempt(false, null)),
            attemptsFor(NativeSecurity.AUTO, null),
        )
        assertEquals(listOf(Attempt(false, 1)), attemptsFor(NativeSecurity.INSECURE, 1))
        assertEquals(listOf(Attempt(true, 3)), attemptsFor(NativeSecurity.SECURE, 3))
    }

    @Test
    fun `returns the first socket that connects`() {
        val tried = mutableListOf<Attempt>()
        val sockets = mutableListOf<FakeSocket>()
        val (socket, attempt) = connector.connect(attemptsFor(NativeSecurity.AUTO, null), 5000) {
            tried += it
            FakeSocket { if (it.secure) throw IOException("read failed, socket might closed") }
                .also(sockets::add)
        }

        assertEquals(Attempt(false, null), attempt)
        assertEquals(tried, attemptsFor(NativeSecurity.AUTO, null))
        assertTrue(sockets[0].closed, "the failed socket is closed")
        assertEquals(sockets[1], socket)
    }

    @Test
    fun `reports every failure`() {
        val e = assertFailsWith<ConnectFailedException> {
            connector.connect(attemptsFor(NativeSecurity.AUTO, null), 5000) { attempt ->
                FakeSocket { throw IOException("no ${if (attempt.secure) "auth" else "service"}") }
            }
        }

        assertEquals("secure: no auth; insecure: no service", e.message)
        assertEquals(2, e.failures.size)
    }

    @Test
    fun `the watchdog closes a connect that hangs`() {
        val sockets = mutableListOf<FakeSocket>()
        val start = System.nanoTime()
        val e = assertFailsWith<ConnectTimeoutException> {
            connector.connect(attemptsFor(NativeSecurity.AUTO, null), 200) {
                lateinit var socket: FakeSocket
                socket = FakeSocket { socket.hangUntilClosed() }
                socket.also(sockets::add)
            }
        }
        val ms = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start)

        assertTrue(ms in 150..3000, "took $ms ms")
        assertEquals(1, sockets.size, "no second try after the time is up")
        assertTrue(sockets.single().closed)
        assertTrue(e.message!!.startsWith("No connection in 200 ms"), e.message)
    }

    @Test
    fun `a device that does not answer is not tried again`() {
        var now = 0L
        val connector = Connector(watchdog, pauseMs = 300, clock = { now }, sleep = { now += it })
        var tries = 0

        val e = assertFailsWith<ConnectFailedException> {
            connector.connect(attemptsFor(NativeSecurity.AUTO, null), 30_000) {
                tries++
                FakeSocket {
                    now += 12_800
                    throw IOException("read failed, socket might closed or timeout, read ret: -1")
                }
            }
        }

        assertEquals(1, tries)
        assertTrue(e.message!!.contains("no answer in 12800 ms"), e.message)
    }

    @Test
    fun `stops trying when the time runs out between tries`() {
        var now = 0L
        val slow = Connector(watchdog, pauseMs = 300, unreachableAfterMs = 60_000, clock = { now }, sleep = { now += it })
        var tries = 0

        assertFailsWith<ConnectTimeoutException> {
            slow.connect(attemptsFor(NativeSecurity.AUTO, null), 1000) {
                tries++
                FakeSocket {
                    now += 800
                    throw IOException("page timeout")
                }
            }
        }
        assertEquals(1, tries)
    }
}
