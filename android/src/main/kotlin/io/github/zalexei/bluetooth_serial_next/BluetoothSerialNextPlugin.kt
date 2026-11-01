// Copyright 2026 Alexei Zalogin. Use of this source code is governed by the MIT license in the LICENSE file.
package io.github.zalexei.bluetooth_serial_next

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService

class BluetoothSerialNextPlugin : FlutterPlugin, ActivityAware, BluetoothSerialHostApi {
    private var context: Context? = null
    private var adapter: BluetoothAdapter? = null
    private var flutterApi: BluetoothSerialFlutterApi? = null
    private var permissions: BluetoothPermissions? = null
    private var activityBinding: ActivityPluginBinding? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // Connects block for seconds and several may run at once; closes are quick.
    private lateinit var background: ExecutorService
    private lateinit var watchdog: ScheduledExecutorService

    // Main thread only.
    private val sessions = mutableMapOf<Long, PortSession>()
    private val opening = mutableSetOf<String>()
    private val bonding = mutableMapOf<String, MutableList<(Boolean) -> Unit>>()
    private var staleFinishes = 0
    private var nextPortId = 1L

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                BluetoothAdapter.ACTION_STATE_CHANGED -> {
                    val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.STATE_OFF)
                    if (state != BluetoothAdapter.STATE_ON) {
                        // The sockets die with the radio; say why.
                        sessions.values.toList().forEach { closeSession(it, SerialErrors.adapterOff()) }
                        failBonds()
                        staleFinishes = 0
                    }
                    flutterApi?.onAdapterStateChanged(adapterStateOf(state)) {}
                }
                BluetoothDevice.ACTION_FOUND -> {
                    val device = intent.bluetoothDevice() ?: return
                    val rssi = intent.getShortExtra(BluetoothDevice.EXTRA_RSSI, Short.MIN_VALUE)
                    flutterApi?.onDeviceFound(
                        describe(device).copy(rssi = rssi.takeIf { it != Short.MIN_VALUE }?.toLong()),
                    ) {}
                }
                BluetoothAdapter.ACTION_DISCOVERY_FINISHED ->
                    // Each cancel of a running scan ends with this broadcast
                    // too, possibly after the next scan has started; that one
                    // is not over.
                    if (staleFinishes > 0) staleFinishes-- else flutterApi?.onDiscoveryFinished {}
                BluetoothDevice.ACTION_BOND_STATE_CHANGED -> {
                    val device = intent.bluetoothDevice() ?: return
                    val state = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE)
                    when (state) {
                        BluetoothDevice.BOND_BONDED -> bonding.remove(device.address)?.forEach { it(true) }
                        BluetoothDevice.BOND_NONE -> bonding.remove(device.address)?.forEach { it(false) }
                    }
                    flutterApi?.onBondStateChanged(describe(device)) {}
                }
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        this.context = context
        adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
        flutterApi = BluetoothSerialFlutterApi(binding.binaryMessenger)
        permissions = BluetoothPermissions(context)
        background = Executors.newCachedThreadPool { Thread(it, "bluetooth_serial_next") }
        watchdog = Executors.newSingleThreadScheduledExecutor { Thread(it, "bluetooth_serial_next watchdog") }
        context.registerReceiverCompat(
            receiver,
            IntentFilter().apply {
                addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
                addAction(BluetoothDevice.ACTION_FOUND)
                addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
                addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
            },
        )
        BluetoothSerialHostApi.setUp(binding.binaryMessenger, this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        BluetoothSerialHostApi.setUp(binding.binaryMessenger, null)
        flutterApi = null
        context?.unregisterReceiver(receiver)
        closeAllSessions()
        failBonds()
        background.shutdown()
        watchdog.shutdown()
        permissions = null
        adapter = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        permissions?.let {
            it.activity = binding.activity
            binding.addRequestPermissionsResultListener(it)
            binding.addActivityResultListener(it)
        }
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        permissions?.let {
            activityBinding?.removeRequestPermissionsResultListener(it)
            activityBinding?.removeActivityResultListener(it)
            it.activity = null
            it.cancelAll()
        }
        activityBinding = null
    }

    // BluetoothSerialHostApi

    override fun reset() {
        closeAllSessions()
    }

    override fun isAvailable(): Boolean = adapter != null

    override fun adapterState(): NativeAdapterState =
        adapter?.let { adapterStateOf(it.state) } ?: NativeAdapterState.OFF

    override fun requestEnable(callback: (Result<Boolean>) -> Unit) = guarded(callback) {
        requirePermissions().requestEnable(requireAdapter()) { callback(Result.success(it)) }
    }

    override fun hasPermissions(scan: Boolean): Boolean = requirePermissions().has(scan)

    override fun requestPermissions(scan: Boolean, callback: (Result<Boolean>) -> Unit) = guarded(callback) {
        requirePermissions().request(scan) { callback(Result.success(it)) }
    }

    override fun bondedDevices(): List<NativeBluetoothDevice> {
        val adapter = requireOnAdapter()
        requireConnectPermission()
        return adapter.bondedDevices.orEmpty().map(::describe).sortedBy { it.name ?: it.address }
    }

    override fun startDiscovery() {
        val adapter = requireOnAdapter()
        val permissions = requirePermissions()
        if (!permissions.has(scan = true)) {
            throw FlutterError(
                SerialErrors.PERMISSION_DENIED,
                "Finding devices needs ${permissions.needed(true).joinToString()}; call requestPermissions(scan: true) first",
            )
        }
        if (permissions.locationOffForScan()) {
            throw FlutterError(
                SerialErrors.PERMISSION_DENIED,
                "Location is off; Android 11 and older find Bluetooth devices only with it on",
            )
        }
        // A scan already running is restarted, so its results come again.
        stopScan(adapter)
        if (!adapter.startDiscovery()) throw FlutterError(SerialErrors.IO_ERROR, "Android did not start a scan")
    }

    override fun cancelDiscovery() {
        val adapter = adapter ?: return
        if (requirePermissions().has(scan = true)) stopScan(adapter)
    }

    private fun stopScan(adapter: BluetoothAdapter) {
        if (adapter.isDiscovering && adapter.cancelDiscovery()) staleFinishes++
    }

    override fun bond(address: String, callback: (Result<Boolean>) -> Unit) = guarded(callback) {
        val device = remoteDevice(address)
        requireConnectPermission()
        if (device.bondState == BluetoothDevice.BOND_BONDED) return@guarded callback(Result.success(true))
        val waiters = bonding.getOrPut(device.address) { mutableListOf() }
        waiters += { bonded -> callback(Result.success(bonded)) }
        // Already pairing (the system asked on its own, or a second call):
        // wait for the same answer.
        if (waiters.size == 1 && device.bondState != BluetoothDevice.BOND_BONDING && !device.createBond()) {
            bonding.remove(device.address)
            callback(Result.failure(FlutterError(SerialErrors.IO_ERROR, "Android did not start pairing with $address")))
        }
    }

    override fun open(request: NativeOpenRequest, callback: (Result<NativeOpenResult>) -> Unit) = guarded(callback) {
        val adapter = requireOnAdapter()
        requireConnectPermission()
        val device = remoteDevice(request.address)
        val uuid = try {
            UUID.fromString(request.uuid)
        } catch (e: IllegalArgumentException) {
            throw FlutterError(SerialErrors.INVALID_ARGUMENT, "Not a UUID: ${request.uuid}")
        }
        val channel = request.channel?.toInt()
        if (channel != null && channel !in 1..30) {
            throw FlutterError(SerialErrors.INVALID_ARGUMENT, "RFCOMM channels are 1 to 30, not $channel")
        }
        val address = device.address
        if (address in opening || sessions.values.any { it.address == address }) {
            throw FlutterError(SerialErrors.BUSY, "$address is already connected or connecting")
        }
        val scanPermission = requirePermissions().has(scan = true)
        opening += address
        background.execute {
            val result = runCatching {
                // A running scan slows connecting down a lot. Stopping it
                // needs the scan permission on Android 12+.
                if (scanPermission) runCatching { adapter.cancelDiscovery() }
                Connector(watchdog).connect(attemptsFor(request.security, channel), request.timeoutMs) {
                    BluetoothRfcommSocket(createSocket(device, uuid, it))
                }
            }
            mainHandler.post {
                opening -= address
                result.onFailure { callback(Result.failure(connectError(it, device, request))) }
                result.onSuccess { (socket, attempt) -> startSession(address, socket, attempt, callback) }
            }
        }
    }

    override fun write(portId: Long, data: ByteArray, timeoutMs: Long, callback: (Result<Unit>) -> Unit) =
        guarded(callback) {
            val session = sessions[portId] ?: return@guarded callback(Result.failure(SerialErrors.portClosed(portId)))
            session.write(data, timeoutMs.coerceIn(0, Int.MAX_VALUE.toLong()).toInt(), callback)
        }

    override fun close(portId: Long, callback: (Result<Unit>) -> Unit) = guarded(callback) {
        val session = sessions[portId] ?: return@guarded callback(Result.success(Unit))
        closeSession(session, null) { callback(Result.success(Unit)) }
    }

    private val sessionListener = object : PortSession.Listener {
        override fun onData(session: PortSession, data: ByteArray) {
            flutterApi?.onData(session.id, data) {}
        }

        override fun onClosed(session: PortSession, error: FlutterError?) {
            sessions.remove(session.id)
            flutterApi?.onPortClosed(session.id, error?.code, error?.message) {}
        }
    }

    // Helpers

    private fun createSocket(device: BluetoothDevice, uuid: UUID, attempt: Attempt): BluetoothSocket {
        val channel = attempt.channel
        return when {
            channel == null && attempt.secure -> device.createRfcommSocketToServiceRecord(uuid)
            channel == null -> device.createInsecureRfcommSocketToServiceRecord(uuid)
            // No public API connects to a channel without the service lookup,
            // which devices without an SDP record (ELM327 clones) need.
            else -> {
                val name = if (attempt.secure) "createRfcommSocket" else "createInsecureRfcommSocket"
                try {
                    device.javaClass.getMethod(name, Int::class.javaPrimitiveType).invoke(device, channel) as BluetoothSocket
                } catch (e: ReflectiveOperationException) {
                    throw UnsupportedOperationException("This Android does not allow connecting by channel: $e")
                }
            }
        }
    }

    private fun connectError(e: Throwable, device: BluetoothDevice, request: NativeOpenRequest): FlutterError {
        if (adapter?.isEnabled != true) return SerialErrors.adapterOff()
        return when (e) {
            is ConnectTimeoutException -> FlutterError(SerialErrors.TIMEOUT, "${device.address}: ${e.message}")
            is ConnectFailedException -> {
                val secureOnly = request.security == NativeSecurity.SECURE
                if (secureOnly && device.bondState != BluetoothDevice.BOND_BONDED) {
                    FlutterError(SerialErrors.NOT_PAIRED, "${device.address} is not paired: ${e.message}")
                } else {
                    FlutterError(SerialErrors.CONNECTION_FAILED, "${device.address}: ${e.message}")
                }
            }
            else -> SerialErrors.from(e)
        }
    }

    private fun startSession(
        address: String,
        socket: RfcommSocket,
        attempt: Attempt,
        callback: (Result<NativeOpenResult>) -> Unit,
    ) {
        if (flutterApi == null) {
            // The engine went away while connecting.
            background.execute { runCatching { socket.close() } }
            return
        }
        val io = try {
            StreamSerialIo(socket.inputStream, socket.outputStream, socket)
        } catch (e: Throwable) {
            background.execute { runCatching { socket.close() } }
            return callback(Result.failure(SerialErrors.from(e)))
        }
        val session = PortSession(
            id = nextPortId++,
            address = address,
            io = io,
            post = { mainHandler.post(it) },
            readFailure = { if (adapter?.isEnabled == true) SerialErrors.disconnected() else SerialErrors.adapterOff() },
            listener = sessionListener,
        )
        sessions[session.id] = session
        session.start()
        callback(Result.success(NativeOpenResult(portId = session.id, secure = attempt.secure)))
    }

    /**
     * Pigeon does not catch what an async handler throws before it calls
     * back, and Dart would wait forever; answer with the error instead.
     */
    private inline fun <T> guarded(callback: (Result<T>) -> Unit, body: () -> Unit) {
        try {
            body()
        } catch (e: Throwable) {
            callback(Result.failure(SerialErrors.from(e)))
        }
    }

    /** Forgets the session now and closes it in the background. */
    private fun closeSession(session: PortSession, reason: FlutterError?, done: (() -> Unit)? = null) {
        sessions.remove(session.id)
        background.execute {
            session.close(reason)
            done?.let { mainHandler.post(it) }
        }
    }

    private fun closeAllSessions() {
        sessions.values.toList().forEach { closeSession(it, null) }
    }

    private fun failBonds() {
        val waiters = bonding.values.flatten()
        bonding.clear()
        waiters.forEach { it(false) }
    }

    private fun describe(device: BluetoothDevice): NativeBluetoothDevice {
        // Without BLUETOOTH_CONNECT (Android 12+) only the address is known.
        val connect = permissions?.has(scan = false) == true
        return NativeBluetoothDevice(
            address = device.address,
            name = if (connect) runCatching { device.name }.getOrNull() else null,
            bondState = when (if (connect) runCatching { device.bondState }.getOrNull() else null) {
                BluetoothDevice.BOND_BONDED -> NativeBondState.BONDED
                BluetoothDevice.BOND_BONDING -> NativeBondState.BONDING
                else -> NativeBondState.NONE
            },
            type = when (if (connect) runCatching { device.type }.getOrNull() else null) {
                BluetoothDevice.DEVICE_TYPE_CLASSIC -> NativeDeviceType.CLASSIC
                BluetoothDevice.DEVICE_TYPE_LE -> NativeDeviceType.LE
                BluetoothDevice.DEVICE_TYPE_DUAL -> NativeDeviceType.DUAL
                else -> NativeDeviceType.UNKNOWN
            },
            deviceClass = if (connect) {
                runCatching { device.bluetoothClass?.deviceClass?.toLong() }.getOrNull()
            } else {
                null
            },
        )
    }

    private fun remoteDevice(address: String): BluetoothDevice {
        // getRemoteDevice wants upper case and throws on anything else.
        val normalized = address.trim().uppercase()
        if (!BluetoothAdapter.checkBluetoothAddress(normalized)) {
            throw FlutterError(SerialErrors.INVALID_ARGUMENT, "Not a Bluetooth address: $address")
        }
        return requireAdapter().getRemoteDevice(normalized)
    }

    private fun requireConnectPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            !requirePermissions().granted(Manifest.permission.BLUETOOTH_CONNECT)
        ) {
            throw FlutterError(
                SerialErrors.PERMISSION_DENIED,
                "Needs BLUETOOTH_CONNECT; call requestPermissions first",
            )
        }
    }

    private fun requireAdapter(): BluetoothAdapter =
        adapter ?: throw FlutterError(SerialErrors.UNSUPPORTED_OPERATION, "This device has no Bluetooth")

    private fun requireOnAdapter(): BluetoothAdapter =
        requireAdapter().also { if (!it.isEnabled) throw SerialErrors.adapterOff() }

    private fun requirePermissions(): BluetoothPermissions =
        permissions ?: throw FlutterError(SerialErrors.IO_ERROR, "The plugin is not attached to an engine")
}

private class BluetoothRfcommSocket(private val socket: BluetoothSocket) : RfcommSocket {
    override fun connect() = socket.connect()
    override val inputStream get() = socket.inputStream!!
    override val outputStream get() = socket.outputStream!!
    override fun close() = socket.close()
}

private fun adapterStateOf(state: Int): NativeAdapterState = when (state) {
    BluetoothAdapter.STATE_ON -> NativeAdapterState.ON
    BluetoothAdapter.STATE_TURNING_ON -> NativeAdapterState.TURNING_ON
    BluetoothAdapter.STATE_TURNING_OFF -> NativeAdapterState.TURNING_OFF
    else -> NativeAdapterState.OFF
}

private fun Intent.bluetoothDevice(): BluetoothDevice? =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
    } else {
        @Suppress("DEPRECATION")
        getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
    }

private fun Context.registerReceiverCompat(receiver: BroadcastReceiver, filter: IntentFilter) {
    // Exported: these broadcasts come from the Bluetooth app
    // (com.android.bluetooth), not from the system, and a not exported
    // receiver never gets them (seen on Android 16). They are protected
    // broadcasts, so no other app can send them.
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
    } else {
        registerReceiver(receiver, filter)
    }
}
