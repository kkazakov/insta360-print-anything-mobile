package com.wasp.insta360_print_anything_mobile.camera

import kotlin.math.roundToInt

/**
 * Baseline (SOF0) 4:2:0 JPEG encoder with caller-supplied quantisation tables.
 *
 * Pure Kotlin on purpose: the app passes pixels decoded from an
 * `android.graphics.Bitmap`, and the JVM tests can decode the result with
 * `ImageIO` without an Android runtime.
 *
 * The pixel pipeline is JFIF full-range YCbCr, chroma is box-averaged 2x2 and
 * the DCT is the float AAN algorithm from ITU T.81 (the same family libjpeg
 * uses).  No APPn, DRI, restart markers or progressive scans are emitted.
 */
object CameraJpegEncoder {
    /**
     * Zigzag position -> natural (row-major frequency) index, JPEG Annex K.
     * `ZIGZAG[k]` is the index of the coefficient at zigzag position `k`.
     */
    private val ZIGZAG = intArrayOf(
        0, 1, 8, 16, 9, 2, 3, 10,
        17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34,
        27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36,
        29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46,
        53, 60, 61, 54, 47, 55, 62, 63,
    )

    /**
     * For the float AAN DCT the 2-D output for frequency (u, v) is
     * `8 * scale[u] * scale[v]` times the true DCT coefficient; dividing the
     * quantisation table by that factor folds the normalisation and the
     * division into a single multiply (as libjpeg's `fdtbl`).
     */
    private val AAN_SCALE = floatArrayOf(
        1.0f,
        1.387039845f,
        1.306562965f,
        1.175875602f,
        1.0f,
        0.785694958f,
        0.541196100f,
        0.275899379f,
    )

    // Standard Huffman tables from ITU T.81 Annex K.3 (BITS has 16 entries).
    private val DC_LUMA_BITS = intArrayOf(0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0)
    private val DC_LUMA_VALS = intArrayOf(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11)
    private val AC_LUMA_BITS = intArrayOf(0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125)
    private val AC_LUMA_VALS = intArrayOf(
        1, 2, 3, 0, 4, 17, 5, 18, 33, 49, 65, 6, 19, 81, 97, 7,
        34, 113, 20, 50, 129, 145, 161, 8, 35, 66, 177, 193, 21, 82, 209, 240,
        36, 51, 98, 114, 130, 9, 10, 22, 23, 24, 25, 26, 37, 38, 39, 40,
        41, 42, 52, 53, 54, 55, 56, 57, 58, 67, 68, 69, 70, 71, 72, 73,
        74, 83, 84, 85, 86, 87, 88, 89, 90, 99, 100, 101, 102, 103, 104, 105,
        106, 115, 116, 117, 118, 119, 120, 121, 122, 131, 132, 133, 134, 135, 136, 137,
        138, 146, 147, 148, 149, 150, 151, 152, 153, 154, 162, 163, 164, 165, 166, 167,
        168, 169, 170, 178, 179, 180, 181, 182, 183, 184, 185, 186, 194, 195, 196, 197,
        198, 199, 200, 201, 202, 210, 211, 212, 213, 214, 215, 216, 217, 218, 225, 226,
        227, 228, 229, 230, 231, 232, 233, 234, 241, 242, 243, 244, 245, 246, 247, 248,
        249, 250,
    )
    private val DC_CHROMA_BITS = intArrayOf(0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0)
    private val DC_CHROMA_VALS = intArrayOf(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11)
    private val AC_CHROMA_BITS = intArrayOf(0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 119)
    private val AC_CHROMA_VALS = intArrayOf(
        0, 1, 2, 3, 17, 4, 5, 33, 49, 6, 18, 65, 81, 7, 97, 113,
        19, 34, 50, 129, 8, 20, 66, 145, 161, 177, 193, 9, 35, 51, 82, 240,
        21, 98, 114, 209, 10, 22, 36, 52, 225, 37, 241, 23, 24, 25, 26, 38,
        39, 40, 41, 42, 53, 54, 55, 56, 57, 58, 67, 68, 69, 70, 71, 72,
        73, 74, 83, 84, 85, 86, 87, 88, 89, 90, 99, 100, 101, 102, 103, 104,
        105, 106, 115, 116, 117, 118, 119, 120, 121, 122, 130, 131, 132, 133, 134, 135,
        136, 137, 138, 146, 147, 148, 149, 150, 151, 152, 153, 154, 162, 163, 164, 165,
        166, 167, 168, 169, 170, 178, 179, 180, 181, 182, 183, 184, 185, 186, 194, 195,
        196, 197, 198, 199, 200, 201, 202, 210, 211, 212, 213, 214, 215, 216, 217, 218,
        226, 227, 228, 229, 230, 231, 232, 233, 234, 242, 243, 244, 245, 246, 247, 248,
        249, 250,
    )

    private val DC_LUMA = HuffmanTable(DC_LUMA_BITS, DC_LUMA_VALS)
    private val AC_LUMA = HuffmanTable(AC_LUMA_BITS, AC_LUMA_VALS)
    private val DC_CHROMA = HuffmanTable(DC_CHROMA_BITS, DC_CHROMA_VALS)
    private val AC_CHROMA = HuffmanTable(AC_CHROMA_BITS, AC_CHROMA_VALS)

    /** One DHT segment payload: DC0, AC0, DC1, AC1 (exactly 416 bytes). */
    private val DHT_PAYLOAD: ByteArray = buildDhtPayload()

    /**
     * Encode ARGB pixels as a baseline (SOF0), 4:2:0 JPEG using the supplied
     * quantisation tables.
     *
     * @param argb row-major pixels, 0xAARRGGBB (alpha ignored), length >= width*height
     * @param width  image width in pixels, > 0, need not be a multiple of 16
     * @param height image height in pixels, > 0, need not be a multiple of 16
     * @param lumaZigzag   64 quantisation values for table 0, in JPEG zigzag order
     * @param chromaZigzag 64 quantisation values for table 1, in JPEG zigzag order
     * @return complete JPEG bytes
     */
    fun encode(
        argb: IntArray,
        width: Int,
        height: Int,
        lumaZigzag: IntArray,
        chromaZigzag: IntArray,
    ): ByteArray {
        require(width > 0) { "width must be positive, was $width" }
        require(height > 0) { "height must be positive, was $height" }
        require(width.toLong() * height <= Int.MAX_VALUE.toLong()) {
            "image is too large: ${width}x$height"
        }
        val pixels = width * height
        require(argb.size >= pixels) {
            "argb must hold at least $pixels pixels, has ${argb.size}"
        }
        require(lumaZigzag.size == 64) {
            "lumaZigzag must have 64 values, has ${lumaZigzag.size}"
        }
        require(chromaZigzag.size == 64) {
            "chromaZigzag must have 64 values, has ${chromaZigzag.size}"
        }
        require(lumaZigzag.all { it in 1..255 }) { "luma quantisation values must be 1..255" }
        require(chromaZigzag.all { it in 1..255 }) { "chroma quantisation values must be 1..255" }

        return Encoder(argb, width, height, lumaZigzag, chromaZigzag).encode()
    }

    private fun buildDhtPayload(): ByteArray {
        val payload = ByteArray(416)
        var i = 0

        fun putTable(classAndId: Int, bits: IntArray, values: IntArray) {
            payload[i++] = classAndId.toByte()
            for (b in bits) payload[i++] = b.toByte()
            for (v in values) payload[i++] = v.toByte()
        }

        // Order matters: DC0, AC0, DC1, AC1.
        putTable(0x00, DC_LUMA_BITS, DC_LUMA_VALS)
        putTable(0x10, AC_LUMA_BITS, AC_LUMA_VALS)
        putTable(0x01, DC_CHROMA_BITS, DC_CHROMA_VALS)
        putTable(0x11, AC_CHROMA_BITS, AC_CHROMA_VALS)
        check(i == payload.size) { "standard DHT payload must be 416 bytes, built $i" }
        return payload
    }

    /** Build a zigzag-ordered reciprocal quantisation table for the AAN DCT. */
    private fun buildFdtbl(quantZigzag: IntArray): FloatArray {
        val fdtbl = FloatArray(64)
        for (k in 0 until 64) {
            val natural = ZIGZAG[k]
            val u = natural shr 3
            val v = natural and 7
            fdtbl[k] = 1.0f / (quantZigzag[k] * 8.0f * AAN_SCALE[u] * AAN_SCALE[v])
        }
        return fdtbl
    }

    private class Encoder(
        private val argb: IntArray,
        private val width: Int,
        private val height: Int,
        private val lumaZigzag: IntArray,
        private val chromaZigzag: IntArray,
    ) {
        private val out = ByteSink(initialCapacity())
        private val bits = BitWriter(out)
        private val lumaFdtbl = buildFdtbl(lumaZigzag)
        private val chromaFdtbl = buildFdtbl(chromaZigzag)

        // Per-MCU scratch, reused so the hot loop allocates nothing.
        private val yPlane = IntArray(256)
        private val cbPlane = IntArray(256)
        private val crPlane = IntArray(256)
        private val block = FloatArray(64)
        private val quantized = IntArray(64)
        private val dcPred = IntArray(3)

        fun encode(): ByteArray {
            writeHeaders()
            encodeScan()
            bits.flush()
            out.write(0xFF) // EOI
            out.write(0xD9)
            return out.toByteArray()
        }

        private fun initialCapacity(): Int {
            val pixels = width.toLong() * height
            return (pixels / 2).coerceIn(1024L, 16L * 1024 * 1024).toInt()
        }

        private fun writeHeaders() {
            // SOI
            out.write(0xFF)
            out.write(0xD8)

            // DQT: one segment, both 8-bit tables, supplied zigzag order.
            out.write(0xFF)
            out.write(0xDB)
            out.writeU16(132) // 2 length bytes + 2 * (1 id + 64 values)
            out.write(0x00)
            for (v in lumaZigzag) out.write(v)
            out.write(0x01)
            for (v in chromaZigzag) out.write(v)

            // SOF0: 8-bit, 3 components, luma 2x2, chroma 1x1 (4:2:0).
            out.write(0xFF)
            out.write(0xC0)
            out.writeU16(17) // 2 length bytes + 15 payload bytes
            out.write(8)
            out.writeU16(height)
            out.writeU16(width)
            out.write(3)
            out.write(1)
            out.write(0x22)
            out.write(0)
            out.write(2)
            out.write(0x11)
            out.write(1)
            out.write(3)
            out.write(0x11)
            out.write(1)

            // DHT: one segment with all four standard tables.
            out.write(0xFF)
            out.write(0xC4)
            out.writeU16(2 + DHT_PAYLOAD.size)
            out.write(DHT_PAYLOAD)

            // SOS: three components, YCbCr, DC/AC table 0/0, 1/1, 1/1.
            out.write(0xFF)
            out.write(0xDA)
            out.writeU16(12) // 2 length bytes + 10 payload bytes
            out.write(3)
            out.write(1)
            out.write(0x00)
            out.write(2)
            out.write(0x11)
            out.write(3)
            out.write(0x11)
            out.write(0)
            out.write(63)
            out.write(0)
        }

        private fun encodeScan() {
            val mcuCols = (width + 15) shr 4
            val mcuRows = (height + 15) shr 4
            for (my in 0 until mcuRows) {
                val baseY = my shl 4
                for (mx in 0 until mcuCols) {
                    loadMcu(mx shl 4, baseY)
                    for (by in 0..1) {
                        for (bx in 0..1) encodeLumaBlock(by, bx)
                    }
                    encodeChromaBlock(cbPlane, 1, DC_CHROMA, AC_CHROMA)
                    encodeChromaBlock(crPlane, 2, DC_CHROMA, AC_CHROMA)
                }
            }
        }

        /**
         * Convert one 16x16 MCU to full-range YCbCr, clamping source coordinates
         * to the last real pixel so partial MCUs are edge-extended like libjpeg.
         */
        private fun loadMcu(baseX: Int, baseY: Int) {
            var i = 0
            for (y in 0 until 16) {
                var sy = baseY + y
                if (sy >= height) sy = height - 1
                val rowStart = sy * width
                for (x in 0 until 16) {
                    var sx = baseX + x
                    if (sx >= width) sx = width - 1
                    val p = argb[rowStart + sx]
                    val r = (p shr 16) and 0xFF
                    val g = (p shr 8) and 0xFF
                    val b = p and 0xFF
                    // Fixed-point JFIF equations; +32768 rounds before >> 16.
                    yPlane[i] = (19595 * r + 38470 * g + 7471 * b + 32768) shr 16
                    var cb = (-11059 * r - 21710 * g + 32768 * b + (128 shl 16) + 32768) shr 16
                    var cr = (32768 * r - 27439 * g - 5329 * b + (128 shl 16) + 32768) shr 16
                    // Full-range chroma can leave 0..255 for saturated colours.
                    if (cb < 0) cb = 0 else if (cb > 255) cb = 255
                    if (cr < 0) cr = 0 else if (cr > 255) cr = 255
                    cbPlane[i] = cb
                    crPlane[i] = cr
                    i++
                }
            }
        }

        private fun encodeLumaBlock(by: Int, bx: Int) {
            val srcRow = by shl 3 // 0 or 8, in the 16-wide MCU buffer
            val srcCol = bx shl 3
            for (y in 0 until 8) {
                val src = ((srcRow + y) shl 4) + srcCol
                val dst = y shl 3
                for (x in 0 until 8) {
                    block[dst + x] = (yPlane[src + x] - 128).toFloat()
                }
            }
            encodeCoefficients(lumaFdtbl, 0, DC_LUMA, AC_LUMA)
        }

        private fun encodeChromaBlock(
            plane: IntArray,
            component: Int,
            dcTable: HuffmanTable,
            acTable: HuffmanTable,
        ) {
            for (y in 0 until 8) {
                val src = (y shl 1) shl 4
                val dst = y shl 3
                for (x in 0 until 8) {
                    val i = src + (x shl 1)
                    val avg = (plane[i] + plane[i + 1] + plane[i + 16] + plane[i + 17] + 2) shr 2
                    block[dst + x] = (avg - 128).toFloat()
                }
            }
            encodeCoefficients(chromaFdtbl, component, dcTable, acTable)
        }

        private fun encodeCoefficients(
            fdtbl: FloatArray,
            component: Int,
            dcTable: HuffmanTable,
            acTable: HuffmanTable,
        ) {
            forwardDct(block)
            // Quantise in zigzag order: fdtbl already includes the AAN scaling.
            for (k in 0 until 64) {
                quantized[k] = (block[ZIGZAG[k]] * fdtbl[k]).roundToInt()
            }
            encodeDc(component, dcTable)
            encodeAc(acTable)
        }

        /**
         * Float AAN forward DCT, rows then columns (ITU T.81 / libjpeg jfdctflt).
         * Output is scaled by 8 * scale[u] * scale[v]; [fdtbl] compensates.
         */
        private fun forwardDct(a: FloatArray) {
            for (i in 0 until 8) dct1d(a, i shl 3, 1)
            for (i in 0 until 8) dct1d(a, i, 8)
        }

        private fun dct1d(a: FloatArray, offset: Int, stride: Int) {
            val d0 = a[offset]
            val d1 = a[offset + stride]
            val d2 = a[offset + 2 * stride]
            val d3 = a[offset + 3 * stride]
            val d4 = a[offset + 4 * stride]
            val d5 = a[offset + 5 * stride]
            val d6 = a[offset + 6 * stride]
            val d7 = a[offset + 7 * stride]

            val t0 = d0 + d7
            val t7 = d0 - d7
            val t1 = d1 + d6
            val t6 = d1 - d6
            val t2 = d2 + d5
            val t5 = d2 - d5
            val t3 = d3 + d4
            val t4 = d3 - d4

            // Even part.
            val t10 = t0 + t3
            val t13 = t0 - t3
            val t11 = t1 + t2
            val t12 = t1 - t2

            a[offset] = t10 + t11
            a[offset + 4 * stride] = t10 - t11
            val z1 = (t12 + t13) * 0.707106781f
            a[offset + 2 * stride] = t13 + z1
            a[offset + 6 * stride] = t13 - z1

            // Odd part, using the rotator from fig. 4-8 (no extra negations).
            val u10 = t4 + t5
            val u11 = t5 + t6
            val u12 = t6 + t7
            val z5 = (u10 - u12) * 0.382683433f
            val z2 = 0.541196100f * u10 + z5
            val z4 = 1.306562965f * u12 + z5
            val z3 = u11 * 0.707106781f
            val z11 = t7 + z3
            val z13 = t7 - z3

            a[offset + 5 * stride] = z13 + z2
            a[offset + 3 * stride] = z13 - z2
            a[offset + stride] = z11 + z4
            a[offset + 7 * stride] = z11 - z4
        }

        private fun encodeDc(component: Int, table: HuffmanTable) {
            val dc = quantized[0]
            val diff = dc - dcPred[component]
            dcPred[component] = dc
            val category = category(diff)
            table.write(category, bits)
            if (category > 0) {
                bits.write(if (diff < 0) diff + (1 shl category) - 1 else diff, category)
            }
        }

        private fun encodeAc(table: HuffmanTable) {
            var run = 0
            for (k in 1 until 64) {
                val v = quantized[k]
                if (v == 0) {
                    run++
                    continue
                }
                while (run > 15) { // ZRL: sixteen zero coefficients
                    table.write(0xF0, bits)
                    run -= 16
                }
                val category = category(v)
                table.write((run shl 4) or category, bits)
                bits.write(if (v < 0) v + (1 shl category) - 1 else v, category)
                run = 0
            }
            if (run > 0) table.write(0x00, bits) // EOB
        }

        private fun category(value: Int): Int {
            var v = if (value < 0) -value else value
            var n = 0
            while (v != 0) {
                v = v ushr 1
                n++
            }
            return n
        }
    }

    /** Canonical Huffman code table: symbol -> (code, bit length). */
    private class HuffmanTable(bits: IntArray, values: IntArray) {
        private val codes = IntArray(256)
        private val sizes = IntArray(256)

        init {
            var code = 0
            var k = 0
            for (length in 1..16) {
                repeat(bits[length - 1]) {
                    val symbol = values[k++]
                    codes[symbol] = code
                    sizes[symbol] = length
                    code++
                }
                code = code shl 1
            }
            check(k == values.size) { "Huffman value count does not match BITS" }
        }

        fun write(symbol: Int, writer: BitWriter) {
            writer.write(codes[symbol], sizes[symbol])
        }
    }

    /** MSB-first bit writer that byte-stuffs 0x00 after every 0xFF. */
    private class BitWriter(private val out: ByteSink) {
        private var buffer = 0
        private var count = 0

        fun write(value: Int, bits: Int) {
            if (bits == 0) return
            buffer = (buffer shl bits) or (value and ((1 shl bits) - 1))
            count += bits
            while (count >= 8) {
                count -= 8
                val b = (buffer ushr count) and 0xFF
                out.write(b)
                if (b == 0xFF) out.write(0x00) // byte stuffing inside entropy data
                buffer = buffer and ((1 shl count) - 1)
            }
        }

        /** Pad the final byte with 1-bits, as required by the standard. */
        fun flush() {
            if (count == 0) return
            val pad = 8 - count
            write((1 shl pad) - 1, pad)
        }
    }

    /** Minimal growable byte sink; avoids per-byte boxing in the scan loop. */
    private class ByteSink(initialCapacity: Int) {
        private var data = ByteArray(initialCapacity)
        private var size = 0

        fun write(b: Int) {
            if (size == data.size) data = data.copyOf(data.size * 2)
            data[size++] = b.toByte()
        }

        fun write(bytes: ByteArray) {
            if (size + bytes.size > data.size) {
                var capacity = data.size * 2
                while (capacity < size + bytes.size) capacity *= 2
                data = data.copyOf(capacity)
            }
            bytes.copyInto(data, size)
            size += bytes.size
        }

        fun writeU16(value: Int) {
            write((value shr 8) and 0xFF)
            write(value and 0xFF)
        }

        fun toByteArray(): ByteArray = data.copyOf(size)
    }
}
