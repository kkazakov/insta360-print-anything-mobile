package com.wasp.insta360_print_anything_mobile

import com.wasp.insta360_print_anything_mobile.camera.CameraImagePipeline
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Pixel pipeline channel: decode the selected phone photo, fit it to the
 * camera's mode and encode the main/preview/thumbnail JPEGs plus the NV21
 * gallery buffer with the camera's quantisation tables.
 */
class CameraImageChannel : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "insta360_print_anything_mobile/camera_images"
    }

    private val worker = Executors.newSingleThreadExecutor()
    private lateinit var channel: MethodChannel

    fun register(engine: FlutterEngine) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepare" -> prepare(call, result)
            "jpegInfo" -> {
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes == null) {
                    result.error("bad_args", "bytes is required", null)
                    return
                }
                result.success(CameraImagePipeline.jpegInfo(bytes))
            }
            else -> result.notImplemented()
        }
    }

    private fun prepare(call: MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>("sourcePath")
        val width = call.argument<Int>("width")
        val height = call.argument<Int>("height")
        val previewWidth = call.argument<Int>("previewWidth")
        val previewHeight = call.argument<Int>("previewHeight")
        val thumbWidth = call.argument<Int>("thumbWidth")
        val thumbHeight = call.argument<Int>("thumbHeight")
        val luma = call.argument<List<Int>>("lumaZigzag")
        val chroma = call.argument<List<Int>>("chromaZigzag")
        val fit = call.argument<String>("fit") ?: "crop"

        if (sourcePath == null ||
            width == null || height == null ||
            previewWidth == null || previewHeight == null ||
            thumbWidth == null || thumbHeight == null ||
            luma == null || chroma == null
        ) {
            result.error("bad_args", "missing image pipeline arguments", null)
            return
        }

        worker.execute {
            try {
                val prepared = CameraImagePipeline.prepare(
                    sourcePath = sourcePath,
                    targetWidth = width,
                    targetHeight = height,
                    previewWidth = previewWidth,
                    previewHeight = previewHeight,
                    thumbWidth = thumbWidth,
                    thumbHeight = thumbHeight,
                    lumaZigzag = luma.toIntArray(),
                    chromaZigzag = chroma.toIntArray(),
                    fit = fit,
                )
                val payload = mapOf(
                    "mainJpeg" to prepared.mainJpeg,
                    "previewJpeg" to prepared.previewJpeg,
                    "thumbnailJpeg" to prepared.thumbnailJpeg,
                    "nv21" to prepared.nv21,
                    "width" to prepared.width,
                    "height" to prepared.height,
                )
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    result.success(payload)
                }
            } catch (error: Exception) {
                android.util.Log.e("CameraImageChannel", "prepare failed", error)
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    result.error(
                        "image_pipeline_failed",
                        error.message ?: error.toString(),
                        null,
                    )
                }
            }
        }
    }
}
