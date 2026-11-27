import Foundation
import Testing
@testable import CharkleCore

@Suite("Douyin Sync & Playback Parity")
struct DouyinSyncParityTests {
    @Test("SocialPlatform supports Douyin and lossless unknown future platforms with decoupled video predicates")
    func socialPlatformDouyinAndUnknownLosslessCodableAndPredicates() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let douyinData = try encoder.encode(SocialPlatform.douyin)
        #expect(String(data: douyinData, encoding: .utf8) == "\"douyin\"")
        #expect(try decoder.decode(SocialPlatform.self, from: douyinData) == .douyin)
        #expect(SocialPlatform.douyin.displayName == "抖音")
        #expect(SocialPlatform.douyin.postNoun == "作品")
        #expect(SocialPlatform.douyin.openActionLabel == "在抖音打开")
        #expect(!SocialPlatform.douyin.isVideoPlatform)
        #expect(SocialPlatform.douyin.prefersZeroDownloadVideoBookmark)
        #expect(SocialPlatform.douyin.isVerticalFeedPlatform)

        // Lossless unknown future platform decode -> re-encode verbatim without throwing
        let futureJSON = Data("\"futureApp\"".utf8)
        let decodedFuture = try decoder.decode(SocialPlatform.self, from: futureJSON)
        #expect(decodedFuture == .unknown("futureApp"))
        #expect(decodedFuture.rawValue == "futureApp")
        #expect(decodedFuture.displayName == "futureApp")
        #expect(decodedFuture.openActionLabel == "打开原链接")
        #expect(!decodedFuture.isVideoPlatform)
        #expect(!decodedFuture.prefersZeroDownloadVideoBookmark)
        let reencodedFuture = try encoder.encode(decodedFuture)
        #expect(String(data: reencodedFuture, encoding: .utf8) == "\"futureApp\"")

        // Per-item zero-download predicate separates Douyin videos from Douyin photo-notes
        let douyinVideo = SocialPostMetadata(
            platform: .douyin,
            authorName: "MS4wLjABAAAA_internal_sec_uid",
            authorHandle: "MS4wLjABAAAA_internal_sec_uid",
            bodyText: "城市建筑航拍",
            hasVideo: true,
            originalURL: "https://www.douyin.com/video/7412345678901234567",
            videoDurationSeconds: 83
        )
        #expect(douyinVideo.isZeroDownloadVideoBookmark)
        #expect(douyinVideo.displayAuthorName == "抖音用户")
        #expect(douyinVideo.displayHandleLine == nil)
        #expect(douyinVideo.formattedVideoDuration == "1:23")

        let douyinPhotoNote = SocialPostMetadata(
            platform: .douyin,
            authorName: "森屿摄影",
            authorHandle: "senyu_studio",
            bodyText: "胶片色彩参考",
            hasVideo: false,
            originalURL: "https://www.douyin.com/note/7412345678901234568"
        )
        #expect(!douyinPhotoNote.isZeroDownloadVideoBookmark)
        #expect(douyinPhotoNote.displayAuthorName == "森屿摄影")
        #expect(douyinPhotoNote.displayHandleLine == "抖音号 senyu_studio")

        let numericHandleMeta = SocialPostMetadata(
            platform: .douyin,
            authorName: "森屿摄影",
            authorHandle: "1029384756102938",
            bodyText: "测试",
            hasVideo: false,
            originalURL: "https://www.douyin.com/note/7412345678901234569"
        )
        #expect(numericHandleMeta.displayHandleLine == nil)
    }

    @Test("DriveSyncEngine syncs Douyin and unrecognized future SocialPlatform ops losslessly without stalling cursors")
    func driveSyncRoundTripWithDouyinAndUnknownFuturePlatform() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let transport = InMemoryDriveTransport()
        let deviceA = try BackendFixture.makeEngine(dir.appending(path: "PeerA"), transport: transport)
        let deviceB = try BackendFixture.makeEngine(dir.appending(path: "PeerB"), transport: transport)
        try await deviceA.saveSyncConfig(BackendFixture.syncConfig())
        try await deviceB.saveSyncConfig(BackendFixture.syncConfig())

        let pngCover = try BackendFixture.artwork("#161823")
        let douyinPost = SocialPostMetadata(
            platform: .douyin,
            authorName: "光影日记",
            authorHandle: "light_diary",
            bodyText: "赛博朋克色调参考",
            articleTitle: "夜景调色思路",
            attachments: [
                SocialMediaAttachment(
                    kind: .video,
                    url: "https://v3-web.douyinvod.com/sample/video/tos/cn/stream.mp4",
                    thumbnailURL: "https://p3-pc-sign.douyinpic.com/cover.jpeg"
                )
            ],
            hasVideo: true,
            videoURL: "https://v3-web.douyinvod.com/sample/video/tos/cn/stream.mp4",
            likeCount: 1280,
            originalURL: "https://www.douyin.com/video/7412345678901234567",
            videoDurationSeconds: 42.5,
            videoID: "7412345678901234567"
        )
        let futurePost = SocialPostMetadata(
            platform: .unknown("futureApp"),
            authorName: "NovaCreator",
            authorHandle: "nova",
            bodyText: "来自未来平台的作品",
            originalURL: "https://future.example.com/post/999"
        )

        let createdA = try await deviceA.ingest(
            [
                .socialBookmark(douyinPost, coverImageData: pngCover, tags: ["调色"]),
                .socialBookmark(futurePost, coverImageData: pngCover, tags: [])
            ],
            targetFolderID: nil,
            targetBoardID: nil
        )
        #expect(createdA.count == 2)

        _ = try await deviceA.syncNow()
        let syncReportB = try await deviceB.syncNow()
        #expect(syncReportB.downloadedOps >= 2)

        let assetsB = try await deviceB.fetchAssets(matching: FilterCriteria())
        #expect(assetsB.count == 2)

        let syncedDouyin = try #require(assetsB.first(where: { $0.richMetadata?.socialPost?.platform == .douyin }))
        #expect(syncedDouyin.tags.contains("抖音"))
        #expect(syncedDouyin.tags.contains("抖音视频"))
        #expect(syncedDouyin.tags.contains("调色"))
        #expect(syncedDouyin.durationSeconds == 42.5)
        #expect(syncedDouyin.richMetadata?.socialPost?.videoID == "7412345678901234567")

        let syncedFuture = try #require(assetsB.first(where: { $0.richMetadata?.socialPost?.platform == .unknown("futureApp") }))
        let encodedFuture = try JSONEncoder().encode(syncedFuture)
        let jsonString = try #require(String(data: encodedFuture, encoding: .utf8))
        #expect(jsonString.contains("\"platform\":\"futureApp\""))
    }

    @Test("Douyin URL parser, CJK-glued share copy, CDN allowlists, expiry check, and magic-byte sniffing")
    func douyinURLParserShareCopyCDNAndMagicByteSniffing() throws {
        let awemeID = "7412345678901234567"
        let videoURL = try #require(URL(string: "https://www.douyin.com/video/\(awemeID)?previous_page=web_code_link"))
        let modalURL = try #require(URL(string: "https://www.douyin.com/user/MS4wLjABAAAA?modal_id=\(awemeID)&tab=favorite"))
        let shareVideoURL = try #require(URL(string: "https://www.iesdouyin.com/share/video/\(awemeID)/?region=CN"))
        let noteURL = try #require(URL(string: "https://www.douyin.com/note/\(awemeID)"))
        let slidesURL = try #require(URL(string: "https://www.douyin.com/slides/\(awemeID)"))
        let shareSlidesURL = try #require(URL(string: "https://m.douyin.com/share/slides/\(awemeID)"))
        let shortURL = try #require(URL(string: "https://v.douyin.com/iAbCdEfG/"))

        let refVideo = try #require(DouyinURLParser.parse(videoURL))
        let refModal = try #require(DouyinURLParser.parse(modalURL))
        let refShareVideo = try #require(DouyinURLParser.parse(shareVideoURL))
        let refNote = try #require(DouyinURLParser.parse(noteURL))
        let refSlides = try #require(DouyinURLParser.parse(slidesURL))
        let refShareSlides = try #require(DouyinURLParser.parse(shareSlidesURL))
        let refShort = try #require(DouyinURLParser.parse(shortURL))
        let refProtoRel = try #require(DouyinURLParser.parse("//www.douyin.com/note/\(awemeID)"))

        #expect(refVideo.dedupKey == "douyin:\(awemeID)")
        #expect(refModal.dedupKey == "douyin:\(awemeID)")
        #expect(refShareVideo.dedupKey == "douyin:\(awemeID)")
        #expect(refNote.dedupKey == "douyin:\(awemeID)")
        #expect(refSlides.dedupKey == "douyin:\(awemeID)")
        #expect(refShareSlides.dedupKey == "douyin:\(awemeID)")
        #expect(refProtoRel.dedupKey == "douyin:\(awemeID)")

        #expect(!refVideo.isNote)
        #expect(!refModal.isNote)
        #expect(refNote.isNote)
        #expect(refSlides.isNote)
        #expect(refShareSlides.isNote)
        #expect(refProtoRel.isNote)
        #expect(refShort.isShortLink)
        #expect(refNote.canonicalURL.absoluteString == "https://www.douyin.com/note/\(awemeID)")
        #expect(refVideo.canonicalURL.absoluteString == "https://www.douyin.com/video/\(awemeID)")

        // Zero-space CJK-glued mobile share copy extraction
        let shareCopy = "7.48 复制打开抖音，看看【作者的作品】光影教程https://v.douyin.com/iAbCdEfG/复制此链接打开抖音"
        #expect(DouyinURLParser.extractPostURL(from: shareCopy)?.absoluteString == "https://v.douyin.com/iAbCdEfG/")
        #expect(SocialPostURLParser.extractPostURL(from: shareCopy)?.absoluteString == "https://v.douyin.com/iAbCdEfG/")
        #expect(WebURLParser.extractWebURL(from: shareCopy)?.absoluteString == "https://v.douyin.com/iAbCdEfG/")

        // CDN host allowlists
        #expect(DouyinURLParser.isDouyinImageHost("p3-pc-sign.douyinpic.com"))
        #expect(DouyinURLParser.isDouyinImageHost("p9-sign.byteimg.com"))
        #expect(DouyinURLParser.isDouyinVideoHost("v3-web.douyinvod.com"))
        #expect(DouyinURLParser.isDouyinVideoHost("v26-default.zjcdn.com"))
        #expect(DouyinURLParser.isDouyinMediaHost("aweme.snssdk.com"))
        #expect(!DouyinURLParser.isDouyinMediaHost("evil.example.com"))

        // Expiry detection (decimal & hex)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let expiredDec = try #require(URL(string: "https://v3-web.douyinvod.com/a?x-expires=1740000000"))
        let freshDec = try #require(URL(string: "https://v3-web.douyinvod.com/a?x-expires=1760000000"))
        let expiredHexNumeric = try #require(URL(string: "https://v3-web.douyinvod.com/a?expires=66000000"))
        let expiredHexAlpha = try #require(URL(string: "https://v3-web.douyinvod.com/a?expires=66a1b2c3"))
        #expect(DouyinURLParser.isStreamURLExpired(expiredDec, now: now))
        #expect(!DouyinURLParser.isStreamURLExpired(freshDec, now: now))
        #expect(DouyinURLParser.isStreamURLExpired(expiredHexNumeric, now: now))
        #expect(DouyinURLParser.isStreamURLExpired(expiredHexAlpha, now: now))

        // Magic-byte sniffing for application/octet-stream payloads
        #expect(DouyinURLParser.sniffMediaExtension(from: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])) == "png")
        #expect(DouyinURLParser.sniffMediaExtension(from: Data([0xFF, 0xD8, 0xFF, 0xE0])) == "jpg")
        #expect(DouyinURLParser.sniffMediaExtension(from: Data("GIF89a".utf8)) == "gif")
        #expect(DouyinURLParser.sniffMediaExtension(from: Data("RIFF\u{00}\u{00}\u{00}\u{00}WEBP".utf8)) == "webp")
        #expect(DouyinURLParser.sniffMediaExtension(from: Data([0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69, 0x66, 0, 0, 0, 0, 0x6D, 0x69, 0x66, 0x31])) == "avif")
        #expect(DouyinURLParser.sniffMediaExtension(from: Data([0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63, 0, 0, 0, 0, 0x6D, 0x69, 0x66, 0x31])) == "heic")
        #expect(DouyinURLParser.sniffMediaExtension(from: Data([0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D, 0, 0, 0, 0, 0x6D, 0x70, 0x34, 0x32])) == "mp4")
    }

    @Test("Douyin offline RENDER_DATA, _ROUTER_DATA, and OG fallback parsing preserve zero-download video and photo-note parity")
    func douyinOfflineHTMLRouterAndMetaFallbackParsing() throws {
        let videoRef = try #require(DouyinURLParser.parse("https://www.douyin.com/video/7412345678901234567"))
        let renderJSON = """
        {
          "app": {
            "awemeDetail": {
              "aweme_id": "7412345678901234567",
              "desc": "电影感构图解析 #摄影 #电影感",
              "create_time": 1730000000,
              "author": {
                "nickname": "阿川镜头",
                "unique_id": "achuan_lens",
                "avatar_medium": { "url_list": ["https://p3-pc.douyinpic.com/avatar.jpeg"] }
              },
              "statistics": { "digg_count": 4200, "comment_count": 88, "share_count": 310, "play_count": 52000 },
              "text_extra": [
                { "hashtag_name": "摄影" },
                { "hashtag_name": "电影感" }
              ],
              "video": {
                "duration": 65000,
                "origin_cover": { "url_list": ["https://p3-pc-sign.douyinpic.com/cover.jpeg"] },
                "bit_rate": [
                  {
                    "is_h265": 1,
                    "bit_rate": 3000000,
                    "play_addr": { "url_list": ["https://v3-web.douyinvod.com/h265/video/tos/stream"] }
                  },
                  {
                    "is_h265": 0,
                    "bit_rate": 1800000,
                    "play_addr": { "url_list": ["https://v3-web.douyinvod.com/playwm/wm", "https://v3-web.douyinvod.com/h264/video/tos/stream"] }
                  }
                ]
              }
            }
          }
        }
        """
        let encodedRender = try #require(renderJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
        let videoHTML = "<html><head><script id=\"RENDER_DATA\" type=\"application/json\">\(encodedRender)</script></head></html>"

        let parsedVideo = try #require(DouyinPostResolver.parseRouterOrRenderData(html: videoHTML, reference: videoRef))
        #expect(parsedVideo.metadata.platform == .douyin)
        #expect(parsedVideo.metadata.hasVideo)
        #expect(parsedVideo.metadata.authorName == "阿川镜头")
        #expect(parsedVideo.metadata.displayHandleLine == "抖音号 achuan_lens")
        #expect(parsedVideo.metadata.videoDurationSeconds == 65.0)
        #expect(parsedVideo.metadata.videoURL == "https://v3-web.douyinvod.com/h264/video/tos/stream")
        #expect(parsedVideo.primaryMediaDownloadURL == nil)
        #expect(parsedVideo.primaryMediaKind == nil)
        #expect(parsedVideo.primaryThumbnailURL?.absoluteString == "https://p3-pc-sign.douyinpic.com/cover.jpeg")
        #expect(parsedVideo.extractedTags.contains("摄影"))
        #expect(parsedVideo.extractedTags.contains("抖音视频"))

        // Photo-note via window._ROUTER_DATA
        let noteRef = try #require(DouyinURLParser.parse("https://www.douyin.com/note/7412345678901234568"))
        let noteHTML = """
        <html><script>window._ROUTER_DATA = {
          "loaderData": {
            "detail": {
              "aweme_id": "7412345678901234568",
              "aweme_type": 68,
              "desc": "北欧极简展厅参考图",
              "author": { "nickname": "空间档案", "unique_id": "space_archive" },
              "images": [
                { "url_list": ["https://p3-pc-sign.douyinpic.com/img1.heic", "https://p3-pc-sign.douyinpic.com/img1.jpeg"] },
                { "url_list": ["https://p3-pc-sign.douyinpic.com/img2.webp"] }
              ]
            }
          }
        };</script></html>
        """
        let parsedNote = try #require(DouyinPostResolver.parseRouterOrRenderData(html: noteHTML, reference: noteRef))
        #expect(!parsedNote.metadata.hasVideo)
        #expect(!parsedNote.metadata.isZeroDownloadVideoBookmark)
        #expect(parsedNote.metadata.attachments.count == 2)
        #expect(parsedNote.metadata.attachments[0].url == "https://p3-pc-sign.douyinpic.com/img1.jpeg")
        #expect(parsedNote.primaryMediaKind == .photo)
        #expect(parsedNote.extractedTags.contains("抖音图文"))

        // Verification-gated shell returns nil from meta fallback
        let blockedHTML = "<html><head><title>验证码中间页</title></head><body></body></html>"
        #expect(DouyinPostResolver.parseMetaFallback(html: blockedHTML, reference: videoRef) == nil)
    }

    @Test("LocalExtensionBridgeServer ingests Douyin video & photo-note bookmarks with canonical dedup, 900x1440 cards, auto-tags, and streaming plan")
    func localBridgeDouyinVideoAndPhotoNoteIngestDedupAndArtwork() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = try BackendFixture.makeEngine(dir)
        let token = LocalExtensionBridgeServer.generateToken()
        let bridge = LocalExtensionBridgeServer(
            engine: engine,
            token: token,
            preferredPort: 0,
            allowEphemeralPort: true
        )
        let status = try await bridge.start()
        defer { Task { await bridge.stop() } }
        let baseURL = status.baseURL
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        func postJSON(_ path: String, payload: [String: Any]) async throws -> (Int, [String: Any]) {
            var req = URLRequest(url: try #require(URL(string: "\(baseURL)\(path)")))
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            return (code, json)
        }

        let coverDataURL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let awemeVideoID = "7420001122334455667"
        let awemeNoteID = "7420001122334455668"
        let streamURL = "https://v3-web.douyinvod.com/test/video/tos/cn/sample?x-expires=2999999999"

        let videoPayload: [String: Any] = [
            "type": "socialBookmark",
            "platform": "douyin",
            "originalURL": "https://www.douyin.com/video/\(awemeVideoID)?from=favorites",
            "authorName": "视觉实验舱",
            "authorHandle": "visual_lab",
            "articleTitle": "动效曲线拆解",
            "bodyText": "弹性曲线与阻尼参数演示",
            "hasVideo": true,
            "videoURL": streamURL,
            "durationSeconds": 95.0,
            "attachments": [
                ["kind": "video", "url": streamURL, "thumbnailURL": "https://p3-pc-sign.douyinpic.com/vcover.jpeg"]
            ],
            "coverDataUrl": coverDataURL,
            "tags": ["动效"]
        ]
        let notePayload: [String: Any] = [
            "type": "socialBookmark",
            "platform": "douyin",
            "originalURL": "https://www.douyin.com/slides/\(awemeNoteID)",
            "authorName": "排版研究所",
            "authorHandle": "type_studio",
            "articleTitle": "字体网格参考",
            "bodyText": "三栏网格比例实拍",
            "hasVideo": false,
            "attachments": [
                ["kind": "photo", "url": "https://p3-pc-sign.douyinpic.com/p1.jpeg"],
                ["kind": "photo", "url": "https://p3-pc-sign.douyinpic.com/p2.jpeg"]
            ],
            "coverDataUrl": coverDataURL,
            "tags": ["排版"]
        ]

        let (code1, json1) = try await postJSON(
            "/api/v1/assets/ingest",
            payload: ["inputs": [videoPayload, notePayload], "skipDuplicates": true]
        )
        #expect(code1 == 201)
        #expect(json1["created"] as? Int == 2)
        #expect(json1["skipped"] as? Int == 0)

        // Existing sources endpoint exposes canonical `douyin:<aweme_id>` keys
        var existReq = URLRequest(url: try #require(URL(string: "\(baseURL)/api/v1/assets/existing-sources")))
        existReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (existData, _) = try await session.data(for: existReq)
        let existJSON = try #require(JSONSerialization.jsonObject(with: existData) as? [String: Any])
        let canonicalKeys = existJSON["canonicalKeys"] as? [String] ?? []
        #expect(canonicalKeys.contains("douyin:\(awemeVideoID)"))
        #expect(canonicalKeys.contains("douyin:\(awemeNoteID)"))

        // Duplicate ingest via ?modal_id= route skips cleanly
        var dupPayload = videoPayload
        dupPayload["originalURL"] = "https://www.douyin.com/user/self?modal_id=\(awemeVideoID)&showTab=favorite_collection"
        let (codeDup, jsonDup) = try await postJSON(
            "/api/v1/assets/ingest",
            payload: ["inputs": [dupPayload], "skipDuplicates": true]
        )
        #expect(codeDup == 200)
        #expect(jsonDup["created"] as? Int == 0)
        #expect(jsonDup["skipped"] as? Int == 1)

        // Verify persisted Douyin assets: 900x1440 cards, zero-download video (.md original), duration, and classification tags
        let assets = try await engine.fetchAssets(matching: FilterCriteria())
        let savedVideo = try #require(assets.first(where: { $0.richMetadata?.socialPost?.videoID == awemeVideoID }))
        let savedNote = try #require(assets.first(where: { $0.richMetadata?.socialPost?.videoID == awemeNoteID }))

        #expect(savedVideo.mediaKind == .webBookmark)
        #expect(savedVideo.fileName.lowercased().hasSuffix(".md"))
        #expect(savedVideo.pixelWidth == 900)
        #expect(savedVideo.pixelHeight == 1_440)
        #expect(abs(savedVideo.aspectRatio - 0.625) < 0.001)
        #expect(savedVideo.durationSeconds == 95.0)
        #expect(savedVideo.tags.contains("抖音"))
        #expect(savedVideo.tags.contains("抖音视频"))
        #expect(!savedVideo.tags.contains("抖音图文"))

        #expect(savedNote.mediaKind == .webBookmark)
        #expect(savedNote.pixelWidth == 900)
        #expect(savedNote.pixelHeight == 1_440)
        #expect(savedNote.tags.contains("抖音"))
        #expect(savedNote.tags.contains("抖音图文"))
        #expect(!savedNote.tags.contains("抖音视频"))
        #expect(savedNote.richMetadata?.socialPost?.isZeroDownloadVideoBookmark == false)

        // Verify streaming playback plan injects Douyin Referer & video/mp4 MIME override (skips watermarked playwm)
        let savedVideoPost = try #require(savedVideo.richMetadata?.socialPost)
        let plan = await VideoPlatformResolver.resolvePlaybackPlan(for: savedVideoPost)
        let firstStream = try #require(plan.directStreams.first)
        #expect(firstStream.url.absoluteString == streamURL)
        #expect(firstStream.httpHeaders["Referer"] == "https://www.douyin.com/")
        #expect(firstStream.overrideMIMEType == "video/mp4")
    }
}
