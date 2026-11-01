// Copyright 2026 Alexei Zalogin. Use of this source code is governed by the MIT license in the LICENSE file.
package io.github.zalexei.bluetooth_serial_next

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.PluginRegistry

/**
 * Runtime permissions and the "turn Bluetooth on" dialog, both of which need
 * the activity and answer in a callback.
 */
internal class BluetoothPermissions(private val context: Context) :
    PluginRegistry.RequestPermissionsResultListener,
    PluginRegistry.ActivityResultListener {

    var activity: Activity? = null

    private val permissionWaiters = mutableListOf<(Boolean) -> Unit>()
    private val enableWaiters = mutableListOf<(Boolean) -> Unit>()

    /** What connecting, and with [scan] also finding devices, needs at run time. */
    fun needed(scan: Boolean): List<String> = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
            listOfNotNull(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN.takeIf { scan })
        // Android 6 to 11 find devices only with the location permission.
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.M ->
            if (scan) listOf(Manifest.permission.ACCESS_FINE_LOCATION) else emptyList()
        else -> emptyList()
    }

    fun has(scan: Boolean): Boolean = needed(scan).all(::granted)

    fun granted(permission: String): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    fun request(scan: Boolean, callback: (Boolean) -> Unit) {
        val missing = needed(scan).filterNot(::granted)
        if (missing.isEmpty()) return callback(true)
        val activity = activity ?: throw SerialErrors.noActivity("requestPermissions")
        permissionWaiters += callback
        // One dialog for everyone who asks while it is open.
        if (permissionWaiters.size == 1) {
            activity.requestPermissions(missing.toTypedArray(), PERMISSIONS_REQUEST)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSIONS_REQUEST) return false
        val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        val waiters = permissionWaiters.toList()
        permissionWaiters.clear()
        waiters.forEach { it(granted) }
        return true
    }

    fun requestEnable(adapter: BluetoothAdapter, callback: (Boolean) -> Unit) {
        if (adapter.isEnabled) return callback(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !granted(Manifest.permission.BLUETOOTH_CONNECT)) {
            throw FlutterError(
                SerialErrors.PERMISSION_DENIED,
                "Turning Bluetooth on needs BLUETOOTH_CONNECT; call requestPermissions first",
            )
        }
        val activity = activity ?: throw SerialErrors.noActivity("requestEnable")
        enableWaiters += callback
        if (enableWaiters.size == 1) {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE), ENABLE_REQUEST)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != ENABLE_REQUEST) return false
        val waiters = enableWaiters.toList()
        enableWaiters.clear()
        waiters.forEach { it(resultCode == Activity.RESULT_OK) }
        return true
    }

    /** The activity went away: nobody will answer the open dialogs. */
    fun cancelAll() {
        val waiters = permissionWaiters.toList() + enableWaiters.toList()
        permissionWaiters.clear()
        enableWaiters.clear()
        waiters.forEach { it(false) }
    }

    /**
     * Android 6 to 11 also need location turned on in the system to find
     * devices; without it a scan silently finds nothing.
     */
    fun locationOffForScan(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            (context.getSystemService(Context.LOCATION_SERVICE) as LocationManager).isLocationEnabled.not()
        } else {
            @Suppress("DEPRECATION")
            Settings.Secure.getInt(context.contentResolver, Settings.Secure.LOCATION_MODE, 0) ==
                Settings.Secure.LOCATION_MODE_OFF
        }
    }
}

private const val PERMISSIONS_REQUEST = 0x5be1
private const val ENABLE_REQUEST = 0x5be2
