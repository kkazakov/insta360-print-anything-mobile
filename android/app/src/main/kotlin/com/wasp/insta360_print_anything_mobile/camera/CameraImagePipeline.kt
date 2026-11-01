package com.wasp.insta360_print_anything_mobile.camera

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.graphics.Paint
import android.graphics.Rect
import java.io.File

/** The three JPEGs plus the raw gallery thumbnail the trailer needs. */
data class PreparedCameraImages(
    val mainJpeg: ByteArray,
    val previewJpeg: ByteArray,
    val thumbnailJpeg: ByteArray,
    val nv21: ByteArray,
    val width: Int,
    val height: Int,
)

/**
 * Decodes a phone photo at the camera's target size and encodes the three
 * JPEG renditions with the camera's quantisation tables.
 *
 * All pixel work is native: `ImageDecoder` applies EXIF orientation and can
 * downscale huge sources while decoding, and [CameraJpegEncoder] writes the
 * custom DQT. Dart only assembles the container.
 */
object CameraImagePipeline {

    private const val TAG = "CameraImagePipeline"

    fun prepare(
        sourcePath: String,
        targetWidth: Int,
        targetHeight: Int,
        previewWidth: Int,
        previewHeight: Int,
        thumbWidth: Int,
        thumbHeight: Int,
        lumaZigzag: IntArray,
        chromaZigzag: IntArray,
        fit: String,
    ): PreparedCameraImages {
        require(targetWidth > 0 && targetHeight > 0) { "invalid target size" }
        require(previewWidth > 0 && previewHeight > 0) { "invalid preview size" }
        require(thumbWidth > 0 && thumbHeight > 0) { "invalid thumbnail size" }
        require(lumaZigzag.size == 64 && chromaZigzag.size == 64) {
            "quantisation tables must have 64 entries"
        }
        val source = File(sourcePath)
        require(source.isFile) { "source image not found" }

        val started = System.currentTimeMillis()
        val fitted = decodeAndFit(source, targetWidth, targetHeight, fit)
        try {
            val mainPixels = pixelsOf(fitted)
            val mainJpeg = CameraJpegEncoder.encode(
                mainPixels,
                targetWidth,
                targetHeight,
                lumaZigzag,
                chromaZigzag,
            )

            val preview = scaleCrop(fitted, previewWidth, previewHeight)
            val previewPixels = pixelsOf(preview)
            val previewJpeg = CameraJpegEncoder.encode(
                previewPixels,
                previewWidth,
                previewHeight,
                lumaZigzag,
                chromaZigzag,
            )
            val nv21 = CameraNv21.fromRgb(previewPixels, previewWidth, previewHeight)
            preview.recycle()

            val thumb = scaleCrop(fitted, thumbWidth, thumbHeight)
            val thumbJpeg = CameraJpegEncoder.encode(
                pixelsOf(thumb),
                thumbWidth,
                thumbHeight,
                lumaZigzag,
                chromaZigzag,
            )
            thumb.recycle()

            val elapsed = System.currentTimeMillis() - started
            android.util.Log.i(
                TAG,
                "prepared ${targetWidth}x$targetHeight in ${elapsed}ms " +
                    "(main ${mainJpeg.size}B, preview ${previewJpeg.size}B, " +
                    "thumb ${thumbJpeg.size}B, nv21 ${nv21.size}B)",
            )

            return PreparedCameraImages(
                mainJpeg = mainJpeg,
                previewJpeg = previewJpeg,
                thumbnailJpeg = thumbJpeg,
                nv21 = nv21,
                width = targetWidth,
                height = targetHeight,
            )
        } finally {
            fitted.recycle()
        }
    }

    /** Decodes [source] and returns an ARGB_8888 bitmap of exactly tw x th. */
    private fun decodeAndFit(
        source: File,
        tw: Int,
        th: Int,
        fit: String,
    ): Bitmap {
        val imageSource = ImageDecoder.createSource(source)
        var decodedWidth = tw
        var decodedHeight = th
        val decoded = try {
            ImageDecoder.decodeBitmap(imageSource) { decoder, info, _ ->
                val sw = info.size.width.toDouble()
                val sh = info.size.height.toDouble()
                require(sw > 0 && sh > 0) { "source image has no pixels" }
                when (fit) {
                    "stretch" -> {
                        decodedWidth = tw
                        decodedHeight = th
                    }
                    "pad" -> {
                        val scale = minOf(tw / sw, th / sh)
                        decodedWidth = maxOf(1, kotlin.math.round(sw * scale).toInt())
                        decodedHeight = maxOf(1, kotlin.math.round(sh * scale).toInt())
                    }
                    else -> {
                        // cover: decode larger in one dimension, then crop
                        val scale = maxOf(tw / sw, th / sh)
                        decodedWidth = maxOf(tw, kotlin.math.round(sw * scale).toInt())
                        decodedHeight = maxOf(th, kotlin.math.round(sh * scale).toInt())
                    }
                }
                decoder.setTargetSize(decodedWidth, decodedHeight)
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
            }
        } catch (error: ImageDecoder.DecodeException) {
            throw IllegalStateException(
                "Android cannot decode this photo (${error.message ?: "unsupported format"})",
                error,
            )
        }

        val argb = if (decoded.config == Bitmap.Config.ARGB_8888) {
            decoded
        } else {
            decoded.copy(Bitmap.Config.ARGB_8888, false).also { decoded.recycle() }
        }

        val output = Bitmap.createBitmap(tw, th, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        canvas.drawColor(Color.BLACK)
        val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
        val dw = argb.width.toDouble()
        val dh = argb.height.toDouble()

        when (fit) {
            "pad" -> {
                val scale = minOf(tw / dw, th / dh)
                val w = kotlin.math.round(dw * scale).toInt()
                val h = kotlin.math.round(dh * scale).toInt()
                val left = (tw - w) / 2f
                val top = (th - h) / 2f
                canvas.drawBitmap(
                    argb,
                    null,
                    Rect(left.toInt(), top.toInt(), left.toInt() + w, top.toInt() + h),
                    paint,
                )
            }
            "stretch" -> {
                canvas.drawBitmap(argb, null, Rect(0, 0, tw, th), paint)
            }
            else -> {
                // centre crop the decoded cover image into the target frame
                val scale = maxOf(tw / dw, th / dh)
                val cropW = (tw / scale).toInt().coerceIn(1, argb.width)
                val cropH = (th / scale).toInt().coerceIn(1, argb.height)
                val left = ((argb.width - cropW) / 2).coerceAtLeast(0)
                val top = ((argb.height - cropH) / 2).coerceAtLeast(0)
                canvas.drawBitmap(
                    argb,
                    Rect(left, top, left + cropW, top + cropH),
                    Rect(0, 0, tw, th),
                    paint,
                )
            }
        }

        argb.recycle()
        return output
    }

    /** Scale-and-centre-crop [source] to exactly w x h, like fit_image(crop). */
    private fun scaleCrop(source: Bitmap, w: Int, h: Int): Bitmap {
        val output = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
        val sw = source.width.toDouble()
        val sh = source.height.toDouble()
        val scale = maxOf(w / sw, h / sh)
        val cropW = (w / scale).toInt().coerceIn(1, source.width)
        val cropH = (h / scale).toInt().coerceIn(1, source.height)
        val left = ((source.width - cropW) / 2).coerceAtLeast(0)
        val top = ((source.height - cropH) / 2).coerceAtLeast(0)
        canvas.drawBitmap(
            source,
            Rect(left, top, left + cropW, top + cropH),
            Rect(0, 0, w, h),
            paint,
        )
        return output
    }

    private fun pixelsOf(bitmap: Bitmap): IntArray {
        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        return pixels
    }

    /** Bounds-check a produced JPEG without allocating its pixels. */
    fun jpegInfo(bytes: ByteArray): Map<String, Any?> {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        return mapOf(
            "width" to options.outWidth,
            "height" to options.outHeight,
            "mimeType" to options.outMimeType,
        )
    }
}
