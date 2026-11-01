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

    /**
     * Upper bound for the decoded source bitmap. A custom crop can be much
     * smaller than the default centre crop, so decoding at the old cover size
     * would throw away detail; this caps the ARGB working set at ~80 MB.
     */
    private const val MAX_DECODE_PIXELS = 20_000_000.0

    private data class CropSpec(
        val left: Double,
        val top: Double,
        val width: Double,
        val height: Double,
    ) {
        fun isValid(): Boolean =
            left.isFinite() && top.isFinite() && width.isFinite() && height.isFinite() &&
                left >= 0.0 && top >= 0.0 && width > 0.0 && height > 0.0 &&
                left + width <= 1.000001 && top + height <= 1.000001
    }

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
        cropLeft: Double? = null,
        cropTop: Double? = null,
        cropWidth: Double? = null,
        cropHeight: Double? = null,
    ): PreparedCameraImages {
        require(targetWidth > 0 && targetHeight > 0) { "invalid target size" }
        require(previewWidth > 0 && previewHeight > 0) { "invalid preview size" }
        require(thumbWidth > 0 && thumbHeight > 0) { "invalid thumbnail size" }
        require(lumaZigzag.size == 64 && chromaZigzag.size == 64) {
            "quantisation tables must have 64 entries"
        }
        val source = File(sourcePath)
        require(source.isFile) { "source image not found" }
        val crop = parseCrop(cropLeft, cropTop, cropWidth, cropHeight)

        val started = System.currentTimeMillis()
        val fitted = decodeAndFit(source, targetWidth, targetHeight, fit, crop)
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
        crop: CropSpec?,
    ): Bitmap {
        val imageSource = ImageDecoder.createSource(source)
        var decodedWidth = tw
        var decodedHeight = th
        var effectiveCrop: CropSpec? = null
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
                        // The selected crop must end up at least as large as the
                        // target, but the decoded frame is capped so a huge source
                        // cannot allocate an ARGB bitmap larger than ~80 MB.
                        val selected = fitCropToTarget(
                            crop ?: centeredCrop(sw, sh, tw, th),
                            sw,
                            sh,
                            tw,
                            th,
                        )
                        effectiveCrop = selected
                        val cropW = selected.width * sw
                        val cropH = selected.height * sh
                        require(cropW >= 1.0 && cropH >= 1.0) { "crop window is empty" }
                        val needed = maxOf(tw / cropW, th / cropH)
                        val pixelCap = kotlin.math.sqrt(MAX_DECODE_PIXELS / (sw * sh))
                        val scale = minOf(1.0, needed, pixelCap)
                        decodedWidth = maxOf(1, kotlin.math.round(sw * scale).toInt())
                        decodedHeight = maxOf(1, kotlin.math.round(sh * scale).toInt())
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
                val selected = effectiveCrop
                    ?: throw IllegalStateException("crop window was not resolved")
                val left = kotlin.math.round(selected.left * argb.width).toInt()
                    .coerceIn(0, argb.width - 1)
                val top = kotlin.math.round(selected.top * argb.height).toInt()
                    .coerceIn(0, argb.height - 1)
                val right = kotlin.math.round((selected.left + selected.width) * argb.width)
                    .toInt().coerceIn(left + 1, argb.width)
                val bottom = kotlin.math.round((selected.top + selected.height) * argb.height)
                    .toInt().coerceIn(top + 1, argb.height)
                canvas.drawBitmap(
                    argb,
                    Rect(left, top, right, bottom),
                    Rect(0, 0, tw, th),
                    paint,
                )
            }
        }

        argb.recycle()
        return output
    }

    private fun parseCrop(
        left: Double?,
        top: Double?,
        width: Double?,
        height: Double?,
    ): CropSpec? {
        val values = listOf(left, top, width, height)
        if (values.all { it == null }) return null
        require(values.all { it != null }) { "incomplete crop window" }
        val crop = CropSpec(left!!, top!!, width!!, height!!)
        require(crop.isValid()) { "invalid crop window" }
        return crop
    }

    /** The largest target-aspect crop, centred (the old unconditional crop). */
    private fun centeredCrop(sw: Double, sh: Double, tw: Int, th: Int): CropSpec {
        val target = tw.toDouble() / th
        val image = sw / sh
        return if (image > target) {
            val width = target / image
            CropSpec((1 - width) / 2, 0.0, width, 1.0)
        } else {
            val height = image / target
            CropSpec(0.0, (1 - height) / 2, 1.0, height)
        }
    }

    /**
     * Makes [crop]'s pixel aspect equal to the target frame, keeping its centre.
     * The editor already hands us a matching rect; this protects the container
     * if a caller (or a future target mode) is slightly off.
     */
    private fun fitCropToTarget(
        crop: CropSpec,
        sw: Double,
        sh: Double,
        tw: Int,
        th: Int,
    ): CropSpec {
        val target = tw.toDouble() / th
        var left = crop.left * sw
        var top = crop.top * sh
        var width = crop.width * sw
        var height = crop.height * sh
        require(width > 0.0 && height > 0.0) { "crop window is empty" }

        val aspect = width / height
        if (aspect > target) {
            val newWidth = height * target
            left += (width - newWidth) / 2
            width = newWidth
        } else if (aspect < target) {
            val newHeight = width / target
            top += (height - newHeight) / 2
            height = newHeight
        }

        if (width > sw) {
            width = sw
            left = 0.0
        }
        if (height > sh) {
            height = sh
            top = 0.0
        }
        if (left < 0.0) left = 0.0
        if (top < 0.0) top = 0.0
        if (left + width > sw) left = sw - width
        if (top + height > sh) top = sh - height

        return CropSpec(left / sw, top / sh, width / sw, height / sh)
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
