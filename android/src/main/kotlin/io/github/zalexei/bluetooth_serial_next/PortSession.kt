// Copyright 2026 Alexei Zalogin. Use of this source code is governed by the MIT license in the LICENSE file.
package io.github.zalexei.bluetooth_serial_next

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * One open port: a thread that reads, a thread that writes in order, and the
 * close that happens once, whoever starts it. The same design as in
 * usb_serial_next.
 *
 * Knows nothing about Android, so the tests run it on a fake [SerialIo].
 */
internal class PortSession(
    val id: Long,
    val address: String,
    private val io: SerialIo,
    /** Runs a task on the thread that talks to Flutter (the main thread). */
    private val post: (Runnable) -> Unit,
    /** Says why a read failed: a lost link, or Bluetooth turned off. */
    private val readFailure: (Throwable?) -> FlutterError,
    private val listener: Listener,
    private val writer: ExecutorService =
        Executors.newSingleThreadExecutor { Thread(it, "bluetooth_serial_next write $id") },
) {
    interface Listener {
        /** Called on the main thread. */
        fun onData(session: PortSession, data: ByteArray)

        /** Called once, on the main thread, after the last [onData]. */
        fun onClosed(session: PortSession, error: FlutterError?)
    }

    private val closed = AtomicBoolean(false)

    @Volatile
    private var closeReason: FlutterError? = null

    // Data read but not yet sent to Dart. Reads that come while a send is
    // queued join it, so a fast device does not flood the main thread with
    // tiny messages.
    private val pending = ByteArrayOutputStream()
    private var sendQueued = false

    val isClosed: Boolean
        get() = closed.get()

    fun start() {
        Thread(::readLoop, "bluetooth_serial_next read $id").apply { isDaemon = true }.start()
    }

    fun write(data: ByteArray, timeoutMs: Int, callback: (Result<Unit>) -> Unit) {
        try {
            writer.execute {
                val result = runCatching {
                    if (closed.get()) throw closedError()
                    io.write(data, timeoutMs)
                }.mapFailure()
                post { callback(result) }
            }
        } catch (e: RejectedExecutionException) {
            callback(Result.failure(closedError()))
        }
    }

    /**
     * Closes the port; [reason] is null for a requested close. Returns false
     * if it was already closed. Blocks while the socket closes, so call it off
     * the main thread.
     */
    fun close(reason: FlutterError? = null): Boolean {
        if (!closed.compareAndSet(false, true)) return false
        closeReason = reason
        // Writes already queued still run and fail as closed.
        writer.shutdown()
        runCatching { io.close() }
        post {
            sendPending()
            listener.onClosed(this, reason)
        }
        return true
    }

    private fun readLoop() {
        val buffer = ByteArray(io.readBufferSize)
        val failure: Throwable? = try {
            while (!closed.get()) {
                val count = io.read(buffer)
                if (count < 0) throw IOException("The device closed the connection")
                if (count > 0) queue(buffer.copyOf(count))
            }
            null
        } catch (e: Throwable) {
            e
        }
        if (!closed.get()) close(readFailure(failure))
    }

    private fun queue(data: ByteArray) {
        synchronized(pending) {
            pending.write(data)
            if (sendQueued) return
            sendQueued = true
        }
        post { sendPending() }
    }

    private fun sendPending() {
        val data = synchronized(pending) {
            sendQueued = false
            pending.toByteArray().also { pending.reset() }
        }
        if (data.isNotEmpty()) listener.onData(this, data)
    }

    private fun closedError(): FlutterError = closeReason ?: SerialErrors.portClosed(id)

    // After a close, the socket's own complaint ("socket closed") says less
    // than why the port was closed.
    private fun <T> Result<T>.mapFailure(): Result<T> = exceptionOrNull()?.let {
        Result.failure(if (closed.get()) closedError() else SerialErrors.from(it))
    } ?: this
}
