// Copyright 2026 Alexei Zalogin. Use of this source code is governed by the MIT license in the LICENSE file.
package io.github.zalexei.bluetooth_serial_next

import java.io.IOException

/** Error codes the Dart side turns into SerialError values (serial_port_core). */
internal object SerialErrors {
    const val PERMISSION_DENIED = "permission_denied"
    const val DEVICE_NOT_FOUND = "device_not_found"
    const val DISCONNECTED = "disconnected"
    const val PORT_CLOSED = "port_closed"
    const val BUSY = "busy"
    const val INVALID_ARGUMENT = "invalid_argument"
    const val UNSUPPORTED_OPERATION = "unsupported_operation"
    const val TIMEOUT = "timeout"
    const val ADAPTER_OFF = "adapter_off"
    const val NOT_PAIRED = "not_paired"
    const val CONNECTION_FAILED = "connection_failed"
    const val IO_ERROR = "io_error"

    fun portClosed(portId: Long) = FlutterError(PORT_CLOSED, "Port $portId is closed")

    fun disconnected() = FlutterError(DISCONNECTED, "The connection was lost")

    fun adapterOff() = FlutterError(ADAPTER_OFF, "Bluetooth is off")

    fun noActivity(what: String) =
        FlutterError(UNSUPPORTED_OPERATION, "$what needs an activity; call it while the app is in the foreground")

    /** Turns what Android threw into an error Dart understands. */
    fun from(e: Throwable): FlutterError = when (e) {
        is FlutterError -> e
        // Before IOException: it is one.
        is WriteTimeoutException -> FlutterError(TIMEOUT, e.message, e.bytesWritten.toLong())
        is SecurityException -> FlutterError(PERMISSION_DENIED, e.message)
        is UnsupportedOperationException -> FlutterError(UNSUPPORTED_OPERATION, e.message)
        is IllegalArgumentException -> FlutterError(INVALID_ARGUMENT, e.message)
        is IOException -> FlutterError(IO_ERROR, e.message ?: e.toString())
        else -> FlutterError(IO_ERROR, e.toString())
    }
}

internal class WriteTimeoutException(val bytesWritten: Int, message: String) : IOException(message)
