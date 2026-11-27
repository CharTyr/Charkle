package com.charkle.android

import com.charkle.android.core.AssetDto
import com.charkle.android.core.AssetRefNodeDto
import com.charkle.android.core.AutoLayoutConfigDto
import com.charkle.android.core.BoardLayoutModeDto
import com.charkle.android.core.BoardNodeDto
import com.charkle.android.core.BoardNodeKindDto
import com.charkle.android.core.BoardRectDto
import com.charkle.android.core.DriveAccountInfoDto
import com.charkle.android.core.DriveSyncConfigDto
import com.charkle.android.core.EngineEventEnvelope
import com.charkle.android.core.MoodboardDocumentDto
import com.charkle.android.core.MoodboardSummaryDto
import com.charkle.android.core.PhotoExifDto
import com.charkle.android.core.SmartFolderDto
import com.charkle.android.core.SocialPostDto
import com.charkle.android.core.SyncReportDto
import com.charkle.android.core.SyncStatusDto
import com.charkle.android.core.TagCountDto
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.decodeFromJsonElement
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalSerializationApi::class)
class CharkleModelsTest {

    private val wireJson = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
        isLenient = true
        coerceInputValues = true
    }

    @Test
    fun moodboardWireFormatMatchesSwiftAndRustKeyedEnums() {
        val doc = MoodboardDocumentDto(
            id = "11111111-2222-3333-4444-555555555555",
            title = "光影情绪板",
            mode = BoardLayoutModeDto.autoEditorial(AutoLayoutConfigDto(columns = 2, spacing = 14.0, style = "magazine")),
            nodes = listOf(
                BoardNodeDto(
                    id = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                    kind = BoardNodeKindDto(assetRef = AssetRefNodeDto(assetId = "99999999-8888-7777-6666-555555555555")),
                    frame = BoardRectDto(10.0, 20.0, 240.0, 300.0)
                )
            )
        )
        val encoded = wireJson.encodeToString(doc)
        assertTrue(encoded.contains("\"autoEditorial\":{\"_0\":"))
        assertFalse("freeform null key must be omitted", encoded.contains("\"freeform\""))
        assertTrue(encoded.contains("\"assetRef\":{\"assetID\":\"99999999-8888-7777-6666-555555555555\""))
        assertFalse("null sibling enum variants must be omitted", encoded.contains("\"note\""))

        val decoded = wireJson.decodeFromString<MoodboardDocumentDto>(encoded)
        assertEquals("光影情绪板", decoded.title)
        assertTrue(decoded.mode.isAutoEditorial)
        assertEquals("magazine", decoded.mode.editorialConfig?.style)
        assertEquals(1, decoded.nodes.size)
        assertEquals("99999999-8888-7777-6666-555555555555", decoded.nodes[0].referencedAssetId)
    }

    @Test
    fun moodboardSummaryDecodesRustFields() {
        val raw = """
            {
              "id": "11111111-2222-3333-4444-555555555555",
              "title": "陶土釉面",
              "subtitle": "",
              "mode": {"freeform": {}},
              "itemCount": 6,
              "previewAssetIDs": ["AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"],
              "paletteHexes": ["#D4A373", "#BA6B55"],
              "pinnedOffline": true,
              "updatedAt": 780000000.0
            }
        """.trimIndent()
        val summary = wireJson.decodeFromString<MoodboardSummaryDto>(raw)
        assertEquals(6, summary.itemCount)
        assertEquals(listOf("#D4A373", "#BA6B55"), summary.paletteHexes)
        assertTrue(summary.pinnedOffline)
        assertFalse(summary.mode.isAutoEditorial)
    }

    @Test
    fun tagCountDecodesRustNameField() {
        val raw = """[{"name":"建筑光影","count":14},{"name":"minimal","count":3}]"""
        val tags = wireJson.decodeFromString<List<TagCountDto>>(raw)
        assertEquals(2, tags.size)
        assertEquals("建筑光影", tags[0].tag)
        assertEquals(14, tags[0].count)
        assertEquals("minimal", tags[1].tag)
    }

    @Test
    fun photoExifDecodesRustWireFieldNames() {
        val raw = """
            {
              "cameraMake": "Leica",
              "cameraModel": "Q3",
              "lensModel": "Summilux 28mm",
              "capturedAt": "2026-05-01T10:00:00Z",
              "exposureTime": "1/500s",
              "fNumber": 1.7,
              "iso": 200,
              "focalLengthMM": 28.0,
              "focalLength35mm": 28,
              "colorProfile": "Display P3"
            }
        """.trimIndent()
        val exif = wireJson.decodeFromString<PhotoExifDto>(raw)
        assertTrue(exif.hasMeaningfulCameraInfo)
        assertEquals("Leica", exif.cameraMake)
        assertEquals("1/500s", exif.exposureTime)
        assertEquals(1.7, exif.apertureFNumber ?: 0.0, 0.001)
        assertEquals(200, exif.isoSpeed)
        assertEquals(28.0, exif.focalLengthMm ?: 0.0, 0.001)
        assertEquals("Display P3", exif.colorSpace)
    }

    @Test
    fun socialPostDecodesBodyTextAndVideoPlatformLabels() {
        val rawPost = """
            {
              "platform": "bilibili",
              "authorName": "视觉研究",
              "authorHandle": "visual_lab",
              "bodyText": "色彩构成的黄金法则",
              "likeCount": 5000000000,
              "originalURL": "https://www.bilibili.com/video/BV1xx"
            }
        """.trimIndent()
        val post = wireJson.decodeFromString<SocialPostDto>(rawPost)
        assertEquals("色彩构成的黄金法则", post.text)
        assertEquals(5_000_000_000L, post.likeCount)
        assertEquals("https://www.bilibili.com/video/BV1xx", post.originalUrl)

        val rawAsset = """
            {
              "id": "11111111-2222-3333-4444-555555555555",
              "title": "色彩教程",
              "richMetadata": { "socialPost": $rawPost }
            }
        """.trimIndent()
        val asset = wireJson.decodeFromString<AssetDto>(rawAsset)
        assertEquals("B站 视频", asset.displayTypeLabel)
    }

    @Test
    fun syncReportAndStatusMatchRustWireContract() {
        val rawReport = """
            {
              "uploadedOps": 4,
              "downloadedOps": 9,
              "discoveredRemoteAssets": 3,
              "updatedBoards": 1,
              "reconciledRenames": 2,
              "downloadedThumbnails": 6,
              "durationSeconds": 1.42
            }
        """.trimIndent()
        val report = wireJson.decodeFromString<SyncReportDto>(rawReport)
        assertEquals(9, report.pulledOps)
        assertEquals(4, report.pushedOps)
        assertEquals(3, report.discoveredRemoteAssets)
        assertEquals(6, report.downloadedThumbnails)

        val idleStatus = wireJson.decodeFromString<SyncStatusDto>("""{"phase":"idle","pendingOpCount":0}""")
        assertFalse(idleStatus.isSyncing)

        val uploadingStatus = wireJson.decodeFromString<SyncStatusDto>(
            """{"phase":{"uploading":{"completed":2,"total":5}},"pendingOpCount":3,"account":{"email":"a@b.com","displayName":null,"source":"Google Drive"}}"""
        )
        assertTrue(uploadingStatus.isSyncing)
        assertEquals("", uploadingStatus.account?.displayName)

        val backendSyncingStatus = wireJson.decodeFromString<SyncStatusDto>(
            """{"phase":"idle","backendStatuses":[{"backendID":"11111111-2222-3333-4444-555555555555","phase":"merging"}]}"""
        )
        assertTrue(backendSyncingStatus.isSyncing)

        val errorStatus = wireJson.decodeFromString<SyncStatusDto>("""{"phase":{"error":"timeout"}}""")
        assertFalse(errorStatus.isSyncing)
    }

    @Test
    fun driveSyncConfigRoundTripPreservesDesktopFields() {
        val raw = """
            {
              "mode": "directAPIWithGDirect",
              "rootFolderName": "CharkleStudio",
              "sharedFolderURLOrID": "folder_abc123",
              "useGDirectIPAcceleration": false,
              "iCloudFolderName": "CharkleICloud",
              "iCloudCustomFolderPath": "/tmp/custom",
              "backends": [
                {
                  "id": "11111111-2222-3333-4444-555555555555",
                  "name": "Studio Drive",
                  "mode": "directAPIWithGDirect",
                  "isEnabled": true,
                  "isPrimary": true,
                  "sharedFolderURLOrID": "folder_abc123",
                  "iCloudContainerIdentifier": "iCloud.com.example"
                }
              ],
              "autoSyncIntervalSeconds": 900,
              "syncThumbnails": true,
              "syncEmbeddings": false
            }
        """.trimIndent()
        val decoded = wireJson.decodeFromString<DriveSyncConfigDto>(raw)
        val reencoded = wireJson.encodeToString(decoded)
        val roundTripped = wireJson.decodeFromString<DriveSyncConfigDto>(reencoded)
        assertEquals("folder_abc123", roundTripped.sharedFolderUrlOrId)
        assertEquals("CharkleICloud", roundTripped.icloudFolderName)
        assertEquals("/tmp/custom", roundTripped.icloudCustomFolderPath)
        assertFalse(roundTripped.useGDirectIpAcceleration)
        assertEquals("iCloud.com.example", roundTripped.backends[0].icloudContainerIdentifier)

        val nullDisplayAccount = wireJson.decodeFromString<DriveAccountInfoDto>(
            """{"email":"demo@example.com","displayName":null,"source":"WebDAV"}"""
        )
        assertEquals("", nullDisplayAccount.displayName)
        assertEquals("demo@example.com", nullDisplayAccount.email)
    }

    @Test
    fun smartFolderAndEngineEventEnvelopesDecodeCleanly() {
        val sfRaw = """
            {
              "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
              "name": "高分暖色插画",
              "colorHex": "#D4A373",
              "sortOrder": 2,
              "rule": {
                "matchMode": "any",
                "tags": ["插画", "配色"],
                "descriptionQuery": "光影",
                "colorHexes": ["#D4A373"],
                "colorTolerance": 22.0,
                "mediaKinds": ["image", "designFile"],
                "minRating": 4
              }
            }
        """.trimIndent()
        val sf = wireJson.decodeFromString<SmartFolderDto>(sfRaw)
        assertEquals("高分暖色插画", sf.name)
        assertEquals(2, sf.sortOrder)
        assertEquals("any", sf.rule.matchMode)
        assertEquals(listOf("插画", "配色"), sf.rule.tags)
        assertEquals(4, sf.rule.minRating)

        val eventRaw = """{"type":"syncProgressiveThumbnails","payload":["11111111-2222-3333-4444-555555555555"]}"""
        val env = wireJson.decodeFromString<EngineEventEnvelope>(eventRaw)
        assertEquals("syncProgressiveThumbnails", env.type)
        assertNotNull(env.payload)
        val ids = wireJson.decodeFromJsonElement<List<String>>(env.payload!!)
        assertEquals(listOf("11111111-2222-3333-4444-555555555555"), ids)
    }
}
