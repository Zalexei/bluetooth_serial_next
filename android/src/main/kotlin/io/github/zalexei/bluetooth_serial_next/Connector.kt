// Copyright 2026 Alexei Zalogin. Use of this source code is governed by the MIT license in the LICENSE file.
package io.github.zalexei.bluetooth_serial_next

import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** An RFCOMM socket before and after it connects; BluetoothSocket in the app. */
internal interface RfcommSocket : Closeable {
    /** Blocks until connected; throws IOException when it fails or is closed. */
    fun connect()

    val inputStream: InputStream
    val outputStream: OutputStream
}

/** One way to reach the device. */
internal data class Attempt(val secure: Boolean, val channel: Int?) {
    override fun toString() = buildString {
        append(if (secure) "secure" else "insecure")
        if (channel != null) append(" channel $channel")
    }
}

internal fun attemptsFor(security: NativeSecurity, channel: Int?): List<Attempt> = when (security) {
    // Secure first: it is what most devices advertise and the only kind a
    // device that needs a PIN (HC-05) takes. ESP32's BluetoothSerial and
    // many cheap modules also take an insecure link, and some only that.
    NativeSecurity.AUTO -> listOf(Attempt(true, channel), Attempt(false, channel))
    NativeSecurity.SECURE -> listOf(Attempt(true, channel))
    NativeSecurity.INSECURE -> listOf(Attempt(false, channel))
}

internal class ConnectTimeoutException(message: String) : IOException(message)

internal class ConnectFailedException(
    message: String,
    val failures: List<Pair<Attempt, IOException>>,
) : IOException(message)

/**
 * Tries [attempts] in order until one connects, all within [timeoutMs].
 * BluetoothSocket.connect has no timeout of its own and can hang for long,
 * so a watchdog closes the socket when the time is up.
 */
internal class Connector(
    private val watchdog: ScheduledExecutorService,
    private val pauseMs: Long = PAUSE_BETWEEN_ATTEMPTS_MS,
    /**
     * A try that fails this late means the device did not answer the page
     * at all (off or out of range: about 13 s on a Xiaomi 14T Pro); another
     * kind of link would not answer either. Refused or unauthenticated
     * links fail within a second or two.
     */
    private val unreachableAfterMs: Long = UNREACHABLE_AFTER_MS,
    private val clock: () -> Long = System::currentTimeMillis,
    private val sleep: (Long) -> Unit = Thread::sleep,
) {
    fun connect(
        attempts: List<Attempt>,
        timeoutMs: Long,
        create: (Attempt) -> RfcommSocket,
    ): Pair<RfcommSocket, Attempt> {
        val deadline = clock() + timeoutMs
        val failures = mutableListOf<Pair<Attempt, IOException>>()
        for ((index, attempt) in attempts.withIndex()) {
            if (index > 0) {
                // A socket that just failed can make the next one fail at
                // once if it comes too soon.
                if (clock() + pauseMs >= deadline) break
                sleep(pauseMs)
            }
            val left = deadline - clock()
            if (left <= 0) break
            val socket = create(attempt)
            val started = clock()
            val timedOut = AtomicBoolean(false)
            val alarm = watchdog.schedule({
                timedOut.set(true)
                runCatching { socket.close() }
            }, left, TimeUnit.MILLISECONDS)
            try {
                socket.connect()
                alarm.cancel(false)
                if (!timedOut.get()) return socket to attempt
                // Connected just as the watchdog fired: it is closed now.
                throw IOException("Timed out")
            } catch (e: IOException) {
                alarm.cancel(false)
                runCatching { socket.close() }
                if (timedOut.get()) break
                failures += attempt to e
                if (clock() - started >= unreachableAfterMs) {
                    throw ConnectFailedException(
                        "$attempt: ${e.message} (no answer in ${clock() - started} ms: off or out of range?)",
                        failures,
                    )
                }
            }
        }
        if (clock() >= deadline || failures.size < attempts.size) {
            throw ConnectTimeoutException(
                "No connection in $timeoutMs ms" +
                    failures.joinToString(prefix = if (failures.isEmpty()) "" else "; ", separator = "; ") {
                        "${it.first}: ${it.second.message}"
                    },
            )
        }
        throw ConnectFailedException(
            failures.joinToString("; ") { "${it.first}: ${it.second.message}" },
            failures,
        )
    }
}

private const val PAUSE_BETWEEN_ATTEMPTS_MS = 300L
private const val UNREACHABLE_AFTER_MS = 4000L
