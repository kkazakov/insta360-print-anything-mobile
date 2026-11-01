package com.wasp.insta360_print_anything_mobile

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private lateinit var cameraStorage: CameraStorageChannel
    private lateinit var cameraImages: CameraImageChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        UsbCameraChannel(this).register(flutterEngine)
        cameraStorage = CameraStorageChannel(this)
        cameraStorage.register(flutterEngine)
        cameraImages = CameraImageChannel()
        cameraImages.register(flutterEngine)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (::cameraStorage.isInitialized) {
            cameraStorage.onActivityResult(requestCode, resultCode, data)
        }
    }
}
