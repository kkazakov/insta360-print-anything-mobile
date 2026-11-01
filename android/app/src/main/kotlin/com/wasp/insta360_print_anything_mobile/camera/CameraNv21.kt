package com.wasp.insta360_print_anything_mobile.camera

import kotlin.math.roundToInt

/**
 * ARGB -> NV21 conversion for the GO Ultra's raw gallery thumbnail.
 *
 * Mirrors `nv21_from_image` in the Python tool: full-range JFIF YCbCr first,
 * then video-range scaling (Y to 16..235, chroma to 16..240), then a 2x2 box
 * average of the already-scaled chroma, and finally the camera's buffer layout:
 * the Y plane followed by interleaved **U, then V** pairs at half resolution.
 *
 * The reference tool calls this function `nv21_from_image` and its README says
 * "NV21", but its bytes — and the real camera files — are in NV12 order (U
 * first). Measured against the APP2 preview on two real GO Ultra originals,
 * U-first matches the preview far better than V-first, so U-first is what the
 * camera draws.
 *
 * Pure Kotlin so it can be exercised by JVM tests.
 */
object CameraNv21 {
    /** Full-range 8-bit luma -> video range: round(16 + y * 219 / 255). */
    private val Y_VIDEO = IntArray(256) { (16.0 + it * 219.0 / 255.0).roundToInt() }

    /** Full-range 8-bit chroma -> video range: round(128 + (c - 128) * 224 / 255). */
    private val C_VIDEO = IntArray(256) { (128.0 + (it - 128) * 224.0 / 255.0).roundToInt() }

    /**
     * Convert ARGB pixels to the camera's raw gallery thumbnail layout:
     * video-range BT.601 — Y plane (width*height bytes), then interleaved
     * U,V pairs at half resolution ((width/2)*(height/2)*2 bytes).
     */
    fun fromRgb(argb: IntArray, width: Int, height: Int): ByteArray {
        require(width > 0) { "width must be positive, was $width" }
        require(height > 0) { "height must be positive, was $height" }
        require(width % 2 == 0) { "width must be even, was $width" }
        require(height % 2 == 0) { "height must be even, was $height" }
        require(width.toLong() * height <= Int.MAX_VALUE.toLong()) {
            "image is too large: ${width}x$height"
        }
        val pixels = width * height
        require(argb.size >= pixels) {
            "argb must hold at least $pixels pixels, has ${argb.size}"
        }

        val out = ByteArray(pixels + pixels / 2)
        val halfWidth = width / 2
        for (cy in 0 until height / 2) {
            val row0 = (cy shl 1) * width
            val uvRow = pixels + cy * halfWidth * 2
            for (cx in 0 until halfWidth) {
                val i00 = row0 + (cx shl 1)
                val i01 = i00 + 1
                val i10 = i00 + width
                val i11 = i10 + 1

                val p00 = ycbcr(argb[i00])
                val p01 = ycbcr(argb[i01])
                val p10 = ycbcr(argb[i10])
                val p11 = ycbcr(argb[i11])

                out[i00] = Y_VIDEO[p00 and 0xFF].toByte()
                out[i01] = Y_VIDEO[p01 and 0xFF].toByte()
                out[i10] = Y_VIDEO[p10 and 0xFF].toByte()
                out[i11] = Y_VIDEO[p11 and 0xFF].toByte()

                // Average the already-limited chroma, rounding to nearest.
                val u = (C_VIDEO[(p00 shr 8) and 0xFF] + C_VIDEO[(p01 shr 8) and 0xFF] +
                    C_VIDEO[(p10 shr 8) and 0xFF] + C_VIDEO[(p11 shr 8) and 0xFF] + 2) shr 2
                val v = (C_VIDEO[(p00 shr 16) and 0xFF] + C_VIDEO[(p01 shr 16) and 0xFF] +
                    C_VIDEO[(p10 shr 16) and 0xFF] + C_VIDEO[(p11 shr 16) and 0xFF] + 2) shr 2

                val uv = uvRow + (cx shl 1)
                out[uv] = u.toByte() // camera buffer: U first, then V
                out[uv + 1] = v.toByte()
            }
        }
        return out
    }

    /**
     * Full-range JFIF YCbCr for one 0xAARRGGBB pixel, packed as
     * `y | (cb << 8) | (cr << 16)` to avoid an allocation per pixel.
     * Chroma is clamped to 0..255 like libjpeg does for saturated colours.
     */
    private fun ycbcr(pixel: Int): Int {
        val r = (pixel shr 16) and 0xFF
        val g = (pixel shr 8) and 0xFF
        val b = pixel and 0xFF
        val y = (19595 * r + 38470 * g + 7471 * b + 32768) shr 16
        var cb = (-11059 * r - 21710 * g + 32768 * b + (128 shl 16) + 32768) shr 16
        var cr = (32768 * r - 27439 * g - 5329 * b + (128 shl 16) + 32768) shr 16
        if (cb < 0) cb = 0 else if (cb > 255) cb = 255
        if (cr < 0) cr = 0 else if (cr > 255) cr = 255
        return y or (cb shl 8) or (cr shl 16)
    }
}
