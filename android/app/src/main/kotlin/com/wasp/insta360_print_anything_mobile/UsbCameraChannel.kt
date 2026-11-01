package com.wasp.insta360_print_anything_mobile

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Exposes the Android USB host API to Dart.
 *
 * Stage 1 only needs discovery and access: enumerate attached devices, describe
 * them, and ask the user for permission to open one. The mass-storage transfer
 * itself is stage 2 and will use the same [UsbManager] handle.
 */
class UsbCameraChannel(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "insta360_print_anything_mobile/usb_cameras"

        private const val ACTION_USB_PERMISSION =
            "com.wasp.insta360_print_anything_mobile.USB_PERMISSION"

        /** Give up on the system permission dialog after this long. */
        private const val PERMISSION_TIMEOUT_MS = 30_000L
    }

    private val usbManager: UsbManager? =
        context.getSystemService(Context.USB_SERVICE) as? UsbManager

    private val mainHandler = Handler(Looper.getMainLooper())

    /** deviceName -> the Dart call waiting for that device's permission. */
    private val pendingPermissions = HashMap<String, MethodChannel.Result>()
    private val pendingTimeouts = HashMap<String, Runnable>()
    private var permissionReceiverRegistered = false

    private val permissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(receiverContext: Context?, intent: Intent?) {
            if (intent?.action != ACTION_USB_PERMISSION) return
            val device = intent.getUsbDevice()
            val deviceName = device?.deviceName
            if (deviceName == null) {
                finishAllPending(false)
                return
            }
            val granted = device != null && usbManager?.hasPermission(device) == true
            finishPending(deviceName, granted)
        }
    }

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "supportsUsbHost" -> result.success(hasUsbHostFeature())
            "listDevices" -> runCatching { listDevices() }
                .onSuccess(result::success)
                .onFailure { result.error("usb_scan_failed", it.message, null) }
            "requestPermission" -> {
                val deviceName = call.argument<String>("deviceId")
                if (deviceName == null) {
                    result.error("bad_args", "deviceId is required", null)
                    return
                }
                requestPermission(deviceName, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun hasUsbHostFeature(): Boolean =
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_USB_HOST)

    private fun listDevices(): List<Map<String, Any?>> {
        val manager = usbManager ?: return emptyList()
        return manager.deviceList.values.map { device -> describe(manager, device) }
    }

    private fun describe(manager: UsbManager, device: UsbDevice): Map<String, Any?> {
        val interfaces = ArrayList<Map<String, Int>>(device.interfaceCount)
        var massStorage = false
        for (index in 0 until device.interfaceCount) {
            val intf = device.getInterface(index)
            interfaces.add(
                mapOf(
                    "interfaceClass" to intf.interfaceClass,
                    "interfaceSubclass" to intf.interfaceSubclass,
                    "interfaceProtocol" to intf.interfaceProtocol,
                )
            )
            if (intf.interfaceClass == UsbConstants.USB_CLASS_MASS_STORAGE) {
                massStorage = true
            }
        }

        // Serial number is only readable once the app holds permission, and
        // some hubs throw here; it is informational, so never fail the scan.
        val serialNumber = runCatching { device.serialNumber }.getOrNull()

        return mapOf(
            "deviceId" to device.deviceName,
            "deviceName" to device.deviceName,
            "vendorId" to device.vendorId,
            "productId" to device.productId,
            "manufacturer" to device.manufacturerName,
            "product" to device.productName,
            "serialNumber" to serialNumber,
            "deviceClass" to device.deviceClass,
            "interfaces" to interfaces,
            "massStorage" to massStorage,
            "permissionGranted" to manager.hasPermission(device),
        )
    }

    private fun requestPermission(deviceName: String, result: MethodChannel.Result) {
        val manager = usbManager
        if (manager == null) {
            result.success(false)
            return
        }
        val device = manager.deviceList.values.firstOrNull { it.deviceName == deviceName }
        if (device == null) {
            result.error("no_such_device", "No USB device with id $deviceName", null)
            return
        }
        if (manager.hasPermission(device)) {
            result.success(true)
            return
        }

        ensurePermissionReceiver()
        pendingPermissions[deviceName] = result
        pendingTimeouts[deviceName] = Runnable {
            finishPending(deviceName, false)
        }.also { mainHandler.postDelayed(it, PERMISSION_TIMEOUT_MS) }

        val intent = Intent(ACTION_USB_PERMISSION).apply {
            // Kept inside this app: the broadcast is delivered through a
            // PendingIntent we create, so the dynamic receiver stays private.
            setPackage(context.packageName)
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_MUTABLE
        } else {
            0
        }
        val pendingIntent =
            PendingIntent.getBroadcast(context, 0, intent, flags)

        try {
            manager.requestPermission(device, pendingIntent)
        } catch (error: Exception) {
            finishPending(deviceName, false)
        }
    }

    private fun finishPending(deviceName: String, granted: Boolean) {
        pendingTimeouts.remove(deviceName)?.let(mainHandler::removeCallbacks)
        val result = pendingPermissions.remove(deviceName) ?: return
        result.success(granted)
        if (pendingPermissions.isEmpty()) {
            unregisterPermissionReceiver()
        }
    }

    private fun finishAllPending(granted: Boolean) {
        val names = pendingPermissions.keys.toList()
        names.forEach { finishPending(it, granted) }
    }

    private fun ensurePermissionReceiver() {
        if (permissionReceiverRegistered) return
        val filter = IntentFilter(ACTION_USB_PERMISSION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(permissionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(permissionReceiver, filter)
        }
        permissionReceiverRegistered = true
    }

    private fun unregisterPermissionReceiver() {
        if (!permissionReceiverRegistered) return
        runCatching { context.unregisterReceiver(permissionReceiver) }
        permissionReceiverRegistered = false
    }

    @Suppress("DEPRECATION")
    private fun Intent.getUsbDevice(): UsbDevice? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        } else {
            getParcelableExtra(UsbManager.EXTRA_DEVICE)
        }
    }
}
