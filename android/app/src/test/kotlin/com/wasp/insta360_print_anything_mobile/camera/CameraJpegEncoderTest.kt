package com.wasp.insta360_print_anything_mobile.camera

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.awt.image.BufferedImage
import java.io.ByteArrayInputStream
import javax.imageio.ImageIO
import kotlin.math.abs

class CameraJpegEncoderTest {
    private val lumaQuant = IntArray(64) { 7 }
    private val chromaQuant = IntArray(64) { 9 }

    @Test
    fun gradient32EncodesAndDecodes() {
        val width = 32
        val height = 32
        val pixels = gradient(width, height)

        val jpeg = CameraJpegEncoder.encode(pixels, width, height, lumaQuant, chromaQuant)

        val image = decode(jpeg)
        assertEquals(width, image.width)
        assertEquals(height, image.height)

        val mae = meanAbsoluteError(pixels, image)
        assertTrue("R channel MAE ${mae[0]}", mae[0] < 6.0)
        assertTrue("G channel MAE ${mae[1]}", mae[1] < 6.0)
        assertTrue("B channel MAE ${mae[2]}", mae[2] < 6.0)

        val (segments, sosOffset) = parseSegments(jpeg)
        assertEquals("marker order", listOf(0xDB, 0xC0, 0xC4), segments.map { it.marker })
        assertEquals(0xDA, jpeg[sosOffset + 1].toInt() and 0xFF)
        assertSingleEoiAtEnd(jpeg)
    }

    @Test
    fun partialMcusEncodeForOddSizes() {
        for ((width, height) in listOf(7 to 5, 160 to 120)) {
            val jpeg = CameraJpegEncoder.encode(
                gradient(width, height),
                width,
                height,
                lumaQuant,
                chromaQuant,
            )
            val image = decode(jpeg)
            assertEquals("width for ${width}x$height", width, image.width)
            assertEquals("height for ${width}x$height", height, image.height)
        }
    }

    @Test
    fun markerPayloadsMatchTheSpecifiedLayout() {
        val width = 16
        val height = 8
        val luma = IntArray(64) { 3 + it % 11 } // varied, still in 1..255
        val chroma = IntArray(64) { 200 - it }
        val jpeg = CameraJpegEncoder.encode(gradient(width, height), width, height, luma, chroma)

        val (segments, _) = parseSegments(jpeg)
        assertEquals(listOf(0xDB, 0xC0, 0xC4), segments.map { it.marker })

        // DQT is one segment holding both tables in the supplied zigzag order.
        val dqt = segments.first { it.marker == 0xDB }.payload
        val expectedDqt = ByteArray(130)
        expectedDqt[0] = 0x00
        for (k in 0 until 64) expectedDqt[1 + k] = luma[k].toByte()
        expectedDqt[65] = 0x01
        for (k in 0 until 64) expectedDqt[66 + k] = chroma[k].toByte()
        assertArrayEquals(expectedDqt, dqt)

        // DHT holds DC0 (12 values), AC0 (162), DC1 (12), AC1 (162).
        val dht = segments.first { it.marker == 0xC4 }.payload
        assertEquals("DHT payload size", 416, dht.size)
        assertEquals("DC0 id", 0x00, dht[0].toInt() and 0xFF)
        assertEquals("AC0 id", 0x10, dht[29].toInt() and 0xFF)
        assertEquals("DC1 id", 0x01, dht[208].toInt() and 0xFF)
        assertEquals("AC1 id", 0x11, dht[237].toInt() and 0xFF)

        val sof = segments.first { it.marker == 0xC0 }.payload
        assertEquals("precision", 8, sof[0].toInt() and 0xFF)
        assertEquals("height", height, u16(sof, 1))
        assertEquals("width", width, u16(sof, 3))
        assertEquals("components", 3, sof[5].toInt() and 0xFF)
        assertEquals("Y sampling", 0x22, sof[7].toInt() and 0xFF)
        assertEquals("Cb sampling", 0x11, sof[10].toInt() and 0xFF)
        assertEquals("Cr sampling", 0x11, sof[13].toInt() and 0xFF)
        assertEquals("Y quant table", 0, sof[8].toInt() and 0xFF)
        assertEquals("Cb quant table", 1, sof[11].toInt() and 0xFF)
        assertEquals("Cr quant table", 1, sof[14].toInt() and 0xFF)

        // No APP0/APPn markers at all before the scan.
        assertTrue("no APP markers", segments.none { it.marker in 0xE0..0xEF })
        val sosOffset = findSosOffset(jpeg)
        for (i in 0 until sosOffset - 1) {
            assertFalse(
                "APP0 found before SOS at $i",
                (jpeg[i].toInt() and 0xFF) == 0xFF && (jpeg[i + 1].toInt() and 0xFF) == 0xE0,
            )
        }

        val sosLength = u16(jpeg, sosOffset + 2)
        val sos = jpeg.copyOfRange(sosOffset + 4, sosOffset + 2 + sosLength)
        assertArrayEquals(
            byteArrayOf(3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0),
            sos,
        )
    }

    @Test
    fun singlePixelImageEncodesAndDecodes() {
        val pixels = intArrayOf(0xFF336699.toInt())
        val jpeg = CameraJpegEncoder.encode(pixels, 1, 1, lumaQuant, chromaQuant)
        val image = decode(jpeg)
        assertEquals(1, image.width)
        assertEquals(1, image.height)
    }

    @Test
    fun encodingIsDeterministic() {
        val pixels = gradient(24, 18)
        val first = CameraJpegEncoder.encode(pixels, 24, 18, lumaQuant, chromaQuant)
        val second = CameraJpegEncoder.encode(pixels, 24, 18, lumaQuant, chromaQuant)
        assertArrayEquals(first, second)
    }

    @Test
    fun largeGradientEncodesAndDecodes() {
        val width = 512
        val height = 512
        val pixels = gradient(width, height)

        val started = System.nanoTime()
        val jpeg = CameraJpegEncoder.encode(pixels, width, height, lumaQuant, chromaQuant)
        val elapsedMs = (System.nanoTime() - started) / 1_000_000
        println("512x512 gradient: ${jpeg.size} bytes in ${elapsedMs} ms")

        val image = decode(jpeg)
        assertEquals(width, image.width)
        assertEquals(height, image.height)
    }

    @Test
    fun nv21WhiteIsVideoRangeNeutral() {
        val width = 4
        val height = 4
        val nv21 = CameraNv21.fromRgb(IntArray(width * height) { -1 }, width, height)

        assertEquals(width * height + width * height / 2, nv21.size)
        for (i in 0 until width * height) {
            assertEquals("Y[$i]", 235, nv21[i].toInt() and 0xFF)
        }
        for (i in width * height until nv21.size) {
            assertEquals("chroma[$i]", 128, nv21[i].toInt() and 0xFF)
        }
    }

    @Test
    fun nv21MidGreyUsesLimitedRange() {
        val width = 4
        val height = 4
        val midGrey = IntArray(width * height) { 0xFF808080.toInt() }
        val nv21 = CameraNv21.fromRgb(midGrey, width, height)

        for (i in 0 until width * height) {
            assertEquals("Y[$i]", 126, nv21[i].toInt() and 0xFF)
        }
        for (i in width * height until nv21.size) {
            assertEquals("chroma[$i]", 128, nv21[i].toInt() and 0xFF)
        }
    }

    @Test
    fun nv21WritesUBeforeV() {
        val width = 2
        val height = 2
        val red = IntArray(width * height) { 0xFFFF0000.toInt() }
        val nv21 = CameraNv21.fromRgb(red, width, height)

        assertEquals(6, nv21.size)
        // Full-range luma 76 is stored video-range: round(16 + 76 * 219 / 255) = 81.
        assertEquals("Y", 81, nv21[0].toInt() and 0xFF)
        val u = nv21[4].toInt() and 0xFF
        val v = nv21[5].toInt() and 0xFF
        assertEquals("V (Cr)", 240, v)
        assertEquals("U (Cb)", 90, u)
        assertTrue("camera buffer has U before V, got U=$u V=$v", v > u)
    }

    @Test
    fun invalidInputsAreRejected() {
        val pixels = IntArray(4)
        assertThrows(IllegalArgumentException::class.java) {
            CameraJpegEncoder.encode(pixels, 0, 2, lumaQuant, chromaQuant)
        }
        assertThrows(IllegalArgumentException::class.java) {
            CameraJpegEncoder.encode(IntArray(3), 2, 2, lumaQuant, chromaQuant)
        }
        assertThrows(IllegalArgumentException::class.java) {
            CameraJpegEncoder.encode(pixels, 2, 2, IntArray(63), chromaQuant)
        }
        assertThrows(IllegalArgumentException::class.java) {
            CameraJpegEncoder.encode(pixels, 2, 2, IntArray(64), chromaQuant)
        }
        assertThrows(IllegalArgumentException::class.java) {
            CameraNv21.fromRgb(pixels, 3, 2)
        }
        assertThrows(IllegalArgumentException::class.java) {
            CameraNv21.fromRgb(pixels, 2, 3)
        }
    }

    private fun gradient(width: Int, height: Int): IntArray = IntArray(width * height) { i ->
        val x = i % width
        val y = i / width
        val r = if (width > 1) x * 255 / (width - 1) else 128
        val g = if (height > 1) y * 255 / (height - 1) else 128
        val b = if (width > 1 && height > 1) (x + y) * 255 / (width + height - 2) else 128
        (0xFF shl 24) or (r shl 16) or (g shl 8) or b
    }

    private fun decode(jpeg: ByteArray): BufferedImage {
        val image = ImageIO.read(ByteArrayInputStream(jpeg))
        assertNotNull("ImageIO could not decode the JPEG", image)
        return image!!
    }

    private fun meanAbsoluteError(expected: IntArray, actual: BufferedImage): DoubleArray {
        var red = 0L
        var green = 0L
        var blue = 0L
        for (y in 0 until actual.height) {
            for (x in 0 until actual.width) {
                val source = expected[y * actual.width + x]
                val decoded = actual.getRGB(x, y)
                red += abs(((source shr 16) and 0xFF) - ((decoded shr 16) and 0xFF)).toLong()
                green += abs(((source shr 8) and 0xFF) - ((decoded shr 8) and 0xFF)).toLong()
                blue += abs((source and 0xFF) - (decoded and 0xFF)).toLong()
            }
        }
        val count = (actual.width * actual.height).toDouble()
        return doubleArrayOf(red / count, green / count, blue / count)
    }

    private fun u16(data: ByteArray, offset: Int): Int =
        ((data[offset].toInt() and 0xFF) shl 8) or (data[offset + 1].toInt() and 0xFF)

    private data class Segment(val marker: Int, val payload: ByteArray)

    /** Parse marker segments up to (not including) SOS; returns SOS offset. */
    private fun parseSegments(jpeg: ByteArray): Pair<List<Segment>, Int> {
        assertEquals("SOI", 0xD8, jpeg[1].toInt() and 0xFF)
        var offset = 2
        val segments = ArrayList<Segment>()
        while (true) {
            assertEquals("marker prefix at $offset", 0xFF, jpeg[offset].toInt() and 0xFF)
            val marker = jpeg[offset + 1].toInt() and 0xFF
            val length = u16(jpeg, offset + 2)
            if (marker == 0xDA) return segments to offset
            segments.add(Segment(marker, jpeg.copyOfRange(offset + 4, offset + 2 + length)))
            offset += 2 + length
        }
    }

    private fun findSosOffset(jpeg: ByteArray): Int = parseSegments(jpeg).second

    private fun assertSingleEoiAtEnd(jpeg: ByteArray) {
        assertEquals(0xFF, jpeg[jpeg.size - 2].toInt() and 0xFF)
        assertEquals(0xD9, jpeg[jpeg.size - 1].toInt() and 0xFF)
        var count = 0
        for (i in 0 until jpeg.size - 1) {
            if ((jpeg[i].toInt() and 0xFF) == 0xFF && (jpeg[i + 1].toInt() and 0xFF) == 0xD9) {
                count++
            }
        }
        assertEquals("exactly one EOI marker", 1, count)
    }
}
