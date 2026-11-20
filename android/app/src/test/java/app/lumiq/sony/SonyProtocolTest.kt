package app.lumiq.sony

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.Base64

/** Port of FocalTests/SonyProtocolTests.swift. */
class SonyProtocolTest {
    private val host = "192.168.122.1"
    private val jpeg = bytes(0xff, 0xd8, 0xff, 0xda, 0, 8, 1, 1, 0, 0, 63, 0, 0x10, 0x20, 0xff, 0xd9)

    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    private fun packet(payload: ByteArray, type: Int = 1, padding: Int = 0): ByteArray {
        val h = ByteArray(136)
        h[0] = 0xff.toByte(); h[1] = type.toByte()
        h[8] = 0x24; h[9] = 0x35; h[10] = 0x68; h[11] = 0x79
        h[12] = ((payload.size shr 16) and 0xff).toByte(); h[13] = ((payload.size shr 8) and 0xff).toByte(); h[14] = (payload.size and 0xff).toByte()
        h[15] = padding.toByte()
        return h + payload + ByteArray(padding)
    }

    private fun descriptor(action: String = "http://192.168.122.1:8080/sony", service: String = "camera") = """
        <root xmlns:av="urn:schemas-sony-com:av"><device><modelName>ILCE-7M3</modelName>
        <av:X_ScalarWebAPI_ServiceList><av:X_ScalarWebAPI_Service>
        <av:X_ScalarWebAPI_ServiceType>$service</av:X_ScalarWebAPI_ServiceType>
        <av:X_ScalarWebAPI_ActionList_URL>$action</av:X_ScalarWebAPI_ActionList_URL>
        </av:X_ScalarWebAPI_Service></av:X_ScalarWebAPI_ServiceList></device></root>
    """.trimIndent().toByteArray()

    private fun assertFrames(expected: List<ByteArray>, actual: List<ByteArray>) {
        assertEquals(expected.size, actual.size)
        expected.zip(actual).forEach { (e, a) -> assertArrayEquals(e, a) }
    }

    private fun throws(block: () -> Unit) { try { block(); fail("expected an error") } catch (_: SonyRemoteError) {} }

    @Test fun privateCameraAddressAndSameHostUrlRequired() {
        for (a in listOf(host, "10.0.0.1", "172.16.0.1", "169.254.1.2")) assertTrue(a, SonyEndpoint.validHost(a))
        for (a in listOf("8.8.8.8", "127.0.0.1", "192.168..1", "192.168.122.01", "192.168.122.1.evil", "172.32.0.1", "256.0.0.1", "+192.168.122.1")) {
            assertTrue(a, !SonyEndpoint.validHost(a))
        }
        SonyEndpoint.validate("http://$host:8080/sony/camera", host)
        for (t in listOf("http://example.com/photo.jpg", "http://192.168.0.2/live", "file:///tmp/photo.jpg", "http://user:pass@$host/live")) {
            throws { SonyEndpoint.validate(t, host) }
        }
    }

    @Test fun descriptorUsesAdvertisedEndpointAndModel() {
        val parsed = SonyDescriptor.parse(descriptor(), host)
        assertEquals("ILCE-7M3", parsed.model)
        assertEquals("http://192.168.122.1:8080/sony/camera", parsed.endpoint)
        assertNull(parsed.liveUrl)
        assertEquals("http://$host/sony/camera", SonyDescriptor.parse(descriptor(action = "http://$host/sony/camera"), host).endpoint)
    }

    @Test fun missingOrExternalScalarServiceDoesNotInventSonyStream() {
        throws { SonyDescriptor.parse(descriptor(service = "avContent"), host) }
        throws { SonyDescriptor.parse(descriptor(action = "http://example.com/sony"), host) }
        throws { SonyDescriptor.parse("broken XML".toByteArray(), host) }
    }

    @Test fun descriptorRefusesDoctypeEntities() {
        val evil = "<!DOCTYPE r [<!ENTITY x SYSTEM \"file:///etc/passwd\">]>".toByteArray() + descriptor()
        throws { SonyDescriptor.parse(evil, host) }
    }

    @Test fun fragmentedJpegAndPaddingReassembleExactly() {
        val parser = SonyLiveViewParser()
        val data = packet(jpeg, padding = 4)
        assertTrue(parser.append(data.copyOfRange(0, 5)).isEmpty())
        assertTrue(parser.append(data.copyOfRange(5, 138)).isEmpty())
        assertFrames(listOf(jpeg), parser.append(data.copyOfRange(138, data.size)))
    }

    @Test fun metadataPacketsAreSkippedAndMultipleFramesPreserved() {
        val parser = SonyLiveViewParser()
        assertFrames(listOf(jpeg, jpeg), parser.append(packet(bytes(1, 2, 3), type = 2) + packet(jpeg) + packet(jpeg, padding = 7)))
    }

    @Test fun parserResynchronizesAfterNoise() {
        assertFrames(listOf(jpeg), SonyLiveViewParser().append(ByteArray(251) + packet(jpeg)))
    }

    @Test fun oversizedPacketFailsExplicitly() {
        val header = packet(jpeg); header[12] = 0x7f
        throws { SonyLiveViewParser().append(header) }
    }

    @Test fun eventTelemetryUsesReportedValuesWithoutInventingEv() {
        val values = JSONArray(
            """[{"type":"exposureMode","currentExposureMode":"Aperture"},{"type":"shutterSpeed","currentShutterSpeed":"1/125"},
            {"type":"isoSpeedRate","currentIsoSpeedRate":"400"},{"type":"fNumber","currentFNumber":"2.8"},
            {"type":"exposureCompensation","currentExposureCompensation":3}]""",
        )
        val t = SonyEventValues.telemetry(values)
        assertEquals("Aperture", t.mode); assertEquals("1/125", t.shutter); assertEquals("400", t.iso); assertEquals("2.8", t.aperture)
        assertNull(t.ev)
        assertEquals(0.0, SonyEventValues.telemetry(JSONArray("""[{"type":"exposureCompensation","currentExposureCompensation":0}]""")).ev!!, 0.0)
        assertEquals(SonyTelemetry(), SonyEventValues.telemetry(JSONArray()))
    }

    @Test fun sonyWrapperAndTrailerDoNotInvalidateJpeg() {
        val wrapped = bytes(1, 2, 3) + jpeg + ByteArray(4)
        assertFrames(listOf(jpeg), SonyLiveViewParser().append(packet(wrapped, padding = 5)))
    }

    @Test fun markerOnlyAndSplitSoiStreamsDecode() {
        val parser = SonyLiveViewParser()
        assertTrue(parser.append(bytes(0x11, 0x22, 0xff)).isEmpty())
        assertFrames(listOf(jpeg, jpeg), parser.append(jpeg.copyOfRange(1, jpeg.size) + jpeg))
    }

    @Test fun malformedFrameRecoversToNextCameraFrame() {
        val parser = SonyLiveViewParser()
        assertFrames(listOf(jpeg), parser.append(packet(bytes(0xff, 0xd8, 0x10, 0x20, 0xff, 0xd9)) + packet(jpeg)))
        assertTrue(parser.discardedFrames > 0)
    }

    @Test fun exifThumbnailEoiDoesNotEndOuterJpeg() {
        val length = jpeg.size + 2
        val app = bytes(0xff, 0xe1, length shr 8, length and 0xff) + jpeg
        val outer = bytes(0xff, 0xd8) + app + jpeg.copyOfRange(2, jpeg.size)
        assertFrames(listOf(outer), SonyLiveViewParser().append(packet(outer)))
    }

    @Test fun stuffedBytesRestartsAndProgressiveScansArePreserved() {
        val parser = SonyLiveViewParser()
        val scan = bytes(0xff, 0xda, 0, 8, 1, 1, 0, 0, 63, 0)
        val image = bytes(0xff, 0xd8) + scan + bytes(0x20, 0xff, 0, 0x30, 0xff, 0xd0, 0x40) + scan + bytes(0x50, 0xff, 0xd9)
        val frames = image.flatMap { parser.append(byteArrayOf(it)) }
        assertFrames(listOf(image), frames)
    }

    @Test fun metadataAndPaddingContainingMarkersDoNotCreateImages() {
        val parser = SonyLiveViewParser()
        val imagePacket = packet(jpeg, padding = 8)
        val offset = 136 + jpeg.size
        bytes(0xff, 0xd8, 0x10, 0x20, 0xff, 0xd9, 0, 0).copyInto(imagePacket, offset)
        assertFrames(listOf(jpeg), parser.append(packet(jpeg, type = 2) + imagePacket))
        assertEquals(1, parser.metadataPackets)
    }

    @Test fun truncatedEntropyFrameCanRecoverAtNewSoi() {
        val parser = SonyLiveViewParser()
        assertTrue(parser.append(jpeg.copyOfRange(0, jpeg.size - 2)).isEmpty())
        assertFrames(listOf(jpeg), parser.append(jpeg))
    }

    /** A real 320×240 JPEG (made with an image library), wrapped, padded and fed in 17-byte pieces. */
    @Test fun realEncodedJpegSurvivesWrappedFragmentedStream() {
        val encoded = Base64.getDecoder().decode(REAL_JPEG)
        val stream = packet(bytes(0, 1) + encoded + bytes(0, 0), padding = 7)
        val parser = SonyLiveViewParser()
        val result = (stream.indices step 17).flatMap { parser.append(stream.copyOfRange(it, minOf(stream.size, it + 17))) }
        assertFrames(listOf(encoded), result)
        assertEquals(320 to 240, jpegSize(result.first()))
    }

    /** Width and height from the JPEG's start-of-frame segment. */
    private fun jpegSize(b: ByteArray): Pair<Int, Int> {
        var i = 2
        while (i + 9 < b.size) {
            val marker = b[i + 1].toInt() and 0xff
            val length = ((b[i + 2].toInt() and 0xff) shl 8) or (b[i + 3].toInt() and 0xff)
            if (marker in 0xc0..0xc2) {
                val h = ((b[i + 5].toInt() and 0xff) shl 8) or (b[i + 6].toInt() and 0xff)
                val w = ((b[i + 7].toInt() and 0xff) shl 8) or (b[i + 8].toInt() and 0xff)
                return w to h
            }
            i += 2 + length
        }
        error("no start-of-frame")
    }

    @Test fun liveViewSizeUsesOnlyAdvertisedValues() {
        assertEquals("L", SonyLiveViewSize.largest(JSONArray("""["M",["M","L"]]""")))
        assertEquals("M", SonyLiveViewSize.largest(JSONArray("""[["S","M"]]""")))
        assertNull(SonyLiveViewSize.largest(JSONArray("""["XL"]""")))
    }

    @Test fun apiErrorsExplainRecovery() {
        val refused = SonyAPIError.parse(JSONObject("""{"error":[5,""]}"""), "actTakePicture")!!
        assertEquals(5, refused.code)
        assertTrue(refused.message!!.contains("still-photo")); assertTrue(refused.message!!.contains("actTakePicture"))
        assertTrue(SonyAPIError.parse(JSONObject("""{"error":[40400,""]}"""), "actTakePicture")!!.message!!.contains("memory card"))
    }

    private companion object {
        const val REAL_JPEG = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCADwAUADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDzqiiivjj+kQooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKAP//Z"
    }
}
