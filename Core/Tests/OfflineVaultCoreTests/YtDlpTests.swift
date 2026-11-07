import XCTest
@testable import OfflineVaultCore

final class YtDlpTests: XCTestCase {
    func testIndexArgumentsForPlaylistAndVideo() {
        let pl = YtDlpCommand.indexArguments(sourceURL: "https://www.youtube.com/playlist?list=PL123")
        XCTAssertTrue(pl.contains("--flat-playlist") && pl.contains("--dump-single-json") && pl.contains("--skip-download"))
        XCTAssertFalse(pl.contains("--no-playlist"))
        XCTAssertEqual(pl.suffix(2), ["--", "https://www.youtube.com/playlist?list=PL123"])
        let v = YtDlpCommand.indexArguments(sourceURL: "https://youtu.be/aqz-KE-bpKQ", playlistLimit: 50)
        XCTAssertTrue(v.contains("--no-playlist"))
        XCTAssertEqual(v[v.firstIndex(of: "--playlist-end")! + 1], "50")
    }

    func testChannelURLNormalisedToVideosTab() {
        XCTAssertEqual(YtDlpCommand.normalise(sourceURL: "https://www.youtube.com/@Blender"), "https://www.youtube.com/@Blender/videos")
        XCTAssertEqual(YtDlpCommand.normalise(sourceURL: "youtube.com/channel/UC123/"), "https://youtube.com/channel/UC123/videos")
        XCTAssertEqual(YtDlpCommand.normalise(sourceURL: "https://www.youtube.com/@Blender/playlists"), "https://www.youtube.com/@Blender/playlists")
        XCTAssertEqual(YtDlpCommand.normalise(sourceURL: "https://www.youtube.com/watch?v=abc"), "https://www.youtube.com/watch?v=abc")
        XCTAssertEqual(YtDlpCommand.SourceKind.detect("https://www.youtube.com/@Blender/videos"), .channel)
        XCTAssertEqual(YtDlpCommand.SourceKind.detect("https://www.youtube.com/playlist?list=PL1"), .playlist)
        XCTAssertEqual(YtDlpCommand.SourceKind.detect("https://www.youtube.com/watch?v=abc&list=PL1"), .video)
    }

    func testDownloadArgumentsContainEverythingTheIndexerNeeds() {
        let out = URL(fileURLWithPath: "/Volumes/SSD/Library/videos")
        let archive = out.appendingPathComponent(".yt-dlp-archive.txt")
        let args = YtDlpCommand.downloadArguments(videoURL: "https://www.youtube.com/watch?v=aqz-KE-bpKQ", quality: .p480, outputDirectory: out, archiveFile: archive, ffmpegLocation: URL(fileURLWithPath: "/App/bin"))
        func value(after flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        XCTAssertEqual(value(after: "--format"), YtDlpCommand.formatSelector(.p480))
        XCTAssertTrue(YtDlpCommand.formatSelector(.p480).contains("height<=480"))
        XCTAssertTrue(YtDlpCommand.formatSelector(.p720).contains("height<=720"))
        XCTAssertEqual(value(after: "--merge-output-format"), "mp4")
        XCTAssertEqual(value(after: "--download-archive"), archive.path)
        XCTAssertEqual(value(after: "--paths"), out.path)
        XCTAssertEqual(value(after: "--output"), "%(id)s.%(ext)s")
        XCTAssertEqual(value(after: "--ffmpeg-location"), "/App/bin")
        XCTAssertTrue(args.contains("--write-subs") && args.contains("--write-auto-subs") && args.contains("--write-thumbnail") && args.contains("--write-info-json") && args.contains("--continue") && args.contains("--no-playlist"))
        XCTAssertTrue(value(after: "--progress-template")?.hasPrefix("download:" + YtDlpCommand.progressPrefix) ?? false)
        XCTAssertEqual(args.suffix(2), ["--", "https://www.youtube.com/watch?v=aqz-KE-bpKQ"])
        XCTAssertFalse(YtDlpCommand.downloadArguments(videoURL: "u", quality: .p360, outputDirectory: out, archiveFile: archive, ffmpegLocation: nil).contains("--ffmpeg-location"))
    }

    func testParsesRecordedFlatPlaylist() throws {
        let info = try YtDlpInfo.parse(Fixtures.data("ytdlp_playlist_flat.json"))
        XCTAssertTrue(info.isPlaylist)
        XCTAssertEqual(info.title, "Top Trending Videos of the Week")
        let videos = info.flattenedVideos()
        XCTAssertEqual(videos.count, 3)
        XCTAssertEqual(videos[0].id, "Vh4O04Bpovw")
        XCTAssertEqual(videos[0].duration, 969)
        XCTAssertNotNil(videos[0].title)
        XCTAssertEqual(videos[0].videoURL?.contains("Vh4O04Bpovw"), true)
        XCTAssertNil(videos[0].formats, "flat entries carry no formats")
    }

    func testParsesRecordedSingleVideoAndEstimatesSizes() throws {
        let info = try YtDlpInfo.parse(Fixtures.data("ytdlp_video.json"))
        XCTAssertFalse(info.isPlaylist)
        XCTAssertEqual(info.id, "aqz-KE-bpKQ")
        XCTAssertEqual(info.duration, 635)
        XCTAssertEqual(info.channelName, "Blender")
        XCTAssertEqual(info.flattenedVideos().count, 1)
        XCTAssertEqual(info.upload_date?.count, 8)
        let formats = try XCTUnwrap(info.formats)
        XCTAssertFalse(formats.isEmpty)
        let exact480 = try XCTUnwrap(SizeEstimator.estimate(duration: info.duration, quality: .p480, formats: formats))
        let exact360 = try XCTUnwrap(SizeEstimator.estimate(duration: info.duration, quality: .p360, formats: formats))
        let exact720 = try XCTUnwrap(SizeEstimator.estimate(duration: info.duration, quality: .p720, formats: formats))
        XCTAssertGreaterThan(exact480, 1_000_000)
        XCTAssertLessThanOrEqual(exact360, exact480)
        XCTAssertLessThanOrEqual(exact480, exact720)
        // Flat entries fall back to a bitrate heuristic.
        let heuristic = try XCTUnwrap(SizeEstimator.estimate(duration: 600, quality: .p480))
        XCTAssertEqual(heuristic, Int64(VideoQuality.p480.estimatedKbps * 1000 / 8 * 600))
        XCTAssertNil(SizeEstimator.estimate(duration: nil, quality: .p480))
    }

    func testFlattensNestedChannelTabs() throws {
        let json = """
        {"_type":"playlist","id":"UC1","title":"Chan","entries":[
          {"_type":"playlist","id":"UC1-videos","title":"Videos","entries":[{"_type":"url","id":"vid00000001","title":"One","duration":10},{"_type":"url","id":"vid00000002","title":"Two"}]},
          {"_type":"playlist","id":"UC1-shorts","title":"Shorts","entries":[]},
          {"_type":"url","id":"vid00000003","title":"Three"}
        ]}
        """
        let info = try YtDlpInfo.parse(Data(json.utf8))
        XCTAssertEqual(info.flattenedVideos().map { $0.id! }, ["vid00000001", "vid00000002", "vid00000003"])
    }

    func testProgressParsing() {
        let p = YtDlpProgressParser.parse(line: "OVPROGRESS 1048576 4194304 NA 524288.0 6")
        guard case .progress(let pr)? = p else { return XCTFail("expected progress") }
        XCTAssertEqual(pr.downloadedBytes, 1_048_576); XCTAssertEqual(pr.totalBytes, 4_194_304); XCTAssertEqual(pr.bytesPerSecond, 524_288); XCTAssertEqual(pr.etaSeconds, 6)
        XCTAssertEqual(pr.fraction, 0.25)
        if case .progress(let est)? = YtDlpProgressParser.parse(line: "OVPROGRESS 10 NA 100 NA NA") { XCTAssertEqual(est.totalBytes, 100) } else { XCTFail() }
        if case .progress(let classic)? = YtDlpProgressParser.parse(line: "[download]  45.2% of 12.34MiB at 1.20MiB/s ETA 00:05") { XCTAssertEqual(classic.totalBytes, Int64(12.34 * 1_048_576)) } else { XCTFail() }
        XCTAssertEqual(YtDlpProgressParser.parse(line: "[download] aqz-KE-bpKQ: has already been recorded in the archive"), .alreadyInArchive)
        XCTAssertEqual(YtDlpProgressParser.parse(line: "ERROR: [youtube] abc: Video unavailable"), .error("[youtube] abc: Video unavailable"))
        XCTAssertEqual(YtDlpProgressParser.parse(line: "[download] Destination: /tmp/x.f137.mp4"), .destination("/tmp/x.f137.mp4"))
        XCTAssertEqual(YtDlpProgressParser.parse(line: "[Merger] Merging formats into \"/tmp/x.mp4\""), .status("Merging video and audio…"))
        XCTAssertNil(YtDlpProgressParser.parse(line: "[youtube] Extracting URL"))
    }

    func testFriendlyErrors() {
        XCTAssertEqual(YouTubeService.friendlyError("WARNING: x\nERROR: [youtube] abc: Private video. Sign in if you've been granted access"), "This video is private.")
        XCTAssertEqual(YouTubeService.friendlyError("curl: Could not resolve host"), "No internet connection.")
    }
}
