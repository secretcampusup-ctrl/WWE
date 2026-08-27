import Foundation
import AVFoundation
import MobileVLCKit

/// Downloads an HLS (.m3u8) stream by fetching every segment directly and
/// remuxing them into a single standalone .mp4 file.
///
/// Why not AVAssetDownloadTask? It's Apple's built-in HLS offline API, but it
/// only produces an opaque .movpkg *bundle* meant for in-app AVPlayer
/// playback — it can never be exported/shared as a normal video file. This
/// downloader instead: resolves the playlist, fetches every segment in
/// order, concatenates them into one MPEG-TS file, then uses
/// AVAssetExportSession to remux (not re-encode) that into a real .mp4.
///
/// Limitation: this runs as a Swift Task on the app's own process rather
/// than a background URLSession, so the app needs to stay open (foreground
/// or briefly backgrounded) while a download is in progress.
enum HLSSegmentDownloader {

    enum DownloadError: LocalizedError {
        case invalidPlaylist
        case noSegments
        case encryptedSegments
        case exportFailed(String)
        case vlcFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidPlaylist: return "Could not read the HLS playlist"
            case .noSegments: return "This link has no video segments"
            case .encryptedSegments: return "Encrypted AES segments are not supported"
            case .exportFailed(let msg): return "Could not export video to MP4: \(msg)"
            case .vlcFailed(let msg): return "VLC could not download the video: \(msg)"
            }
        }
    }

    struct Progress {
        let downloadedSegments: Int
        let totalSegments: Int
        var bytesWritten: Int64 = 0
        var totalBytesExpected: Int64 = 0
        var fraction: Double {
            totalSegments > 0 ? Double(downloadedSegments) / Double(totalSegments) : 0
        }
    }

    /// Downloads and remuxes an HLS stream to a local .mp4 file.
    /// - Returns: URL of the produced .mp4 in a temp location — caller must
    ///   move it to its final destination (this function cleans up its temp
    ///   working directory once it returns).
    static func download(
        masterURL: URL,
        headers: [String: String] = [:],
        onProgress: @escaping (Progress) -> Void
    ) async throws -> URL {
        if masterURL.host?.lowercased().contains("project1content.com") == true {
            return try await downloadWithVLC(masterURL: masterURL, headers: headers, onProgress: onProgress)
        }

        var requestHeaders = headers
        if requestHeaders.keys.first(where: { $0.caseInsensitiveCompare("X-Playback-Session-Id") == .orderedSame }) == nil {
            requestHeaders["X-Playback-Session-Id"] = UUID().uuidString
        }
        let playlistText = try await fetchText(masterURL, headers: requestHeaders)
        let mediaPlaylistURL = try resolveMediaPlaylistURL(masterURL: masterURL, masterPlaylistText: playlistText)
        let mediaPlaylistText = mediaPlaylistURL == masterURL
            ? playlistText
            : try await fetchText(mediaPlaylistURL, headers: requestHeaders)

        if mediaPlaylistText.contains("#EXT-X-KEY") && !mediaPlaylistText.contains("METHOD=NONE") {
            throw DownloadError.encryptedSegments
        }

        let segmentURLs = try parseSegmentURLs(playlistText: mediaPlaylistText, baseURL: mediaPlaylistURL)
        guard !segmentURLs.isEmpty else { throw DownloadError.noSegments }
        let initializationURL = parseInitializationURL(playlistText: mediaPlaylistText, baseURL: mediaPlaylistURL)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hls_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // EXT-X-MAP means the segments are fragmented MP4 and require the init
        // fragment before the media fragments. Traditional HLS uses MPEG-TS.
        let combinedPath = tempDir.appendingPathComponent(initializationURL == nil ? "combined.ts" : "combined.mp4")
        FileManager.default.createFile(atPath: combinedPath.path, contents: nil)
        let handle = try FileHandle(forWritingTo: combinedPath)

        if let initializationURL {
            handle.write(try await fetchData(initializationURL, headers: requestHeaders))
        }

        var completed = 0
        for segmentURL in segmentURLs {
            try Task.checkCancellation()
            let data = try await fetchData(segmentURL, headers: requestHeaders)
            handle.write(data)
            completed += 1
            onProgress(Progress(downloadedSegments: completed, totalSegments: segmentURLs.count))
        }
        try? handle.close()

        let combinedAttrs = try? FileManager.default.attributesOfItem(atPath: combinedPath.path)
        let combinedSize = combinedAttrs?[.size] as? Int
        guard let size = combinedSize, size > 10_000 else {
            try? FileManager.default.removeItem(at: tempDir)
            throw DownloadError.exportFailed("The merged file is too small (\(combinedSize ?? 0) bytes)")
        }

        let mp4URL = tempDir.appendingPathComponent("output.mp4")
        if initializationURL != nil {
            // init.mp4 + ordered m4s fragments already form a standalone
            // fragmented MP4; remuxing it is unnecessary and less reliable.
            try FileManager.default.moveItem(at: combinedPath, to: mp4URL)
        } else {
            try await remux(sourceFile: combinedPath, to: mp4URL)
        }

        // Move the finished mp4 out before the temp working directory is
        // removed, so the caller gets a file that survives cleanup.
        let finalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hls_output_\(UUID().uuidString).mp4")
        try FileManager.default.moveItem(at: mp4URL, to: finalURL)
        try? FileManager.default.removeItem(at: tempDir)
        return finalURL
    }

    private static func downloadWithVLC(
        masterURL: URL,
        headers: [String: String],
        onProgress: @escaping (Progress) -> Void
    ) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vlc_hls_\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        let media = VLCMedia(url: masterURL)
        let escapedPath = outputURL.path.replacingOccurrences(of: "'", with: "\\'")
        media.addOption(":sout=#standard{access=file,mux=mp4,dst='\(escapedPath)'}")
        media.addOption(":sout-keep")
        media.addOption(":http-user-agent=AppleCoreMedia/1.0.0.21F90")
        if let referer = headerValue("Referer", in: headers) {
            media.addOption(":http-referrer=\(referer)")
        }
        if let cookie = headerValue("Cookie", in: headers) {
            media.addOption(":http-cookie=\(cookie)")
        }

        let player = VLCMediaPlayer()
        player.media = media
        player.audio?.isMuted = true
        player.play()
        defer {
            player.stop()
            if Task.isCancelled { try? FileManager.default.removeItem(at: outputURL) }
        }

        let startedAt = Date()
        var hasStarted = false
        var stoppedChecks = 0
        var lastSize: UInt64 = 0
        var stableSizeChecks = 0

        while Date().timeIntervalSince(startedAt) < 24 * 60 * 60 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 500_000_000)

            let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
            let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            if size > 0 || player.isPlaying { hasStarted = true }

            if size == lastSize, size > 10_000 {
                stableSizeChecks += 1
            } else {
                stableSizeChecks = 0
                lastSize = size
            }

            let fraction = min(0.99, max(0, Double(player.position)))
            let written = Int64(clamping: size)
            let estimatedTotal = fraction > 0.02 ? Int64(Double(written) / fraction) : 0
            onProgress(Progress(
                downloadedSegments: Int(fraction * 1000),
                totalSegments: 1000,
                bytesWritten: written,
                totalBytesExpected: estimatedTotal
            ))

            if hasStarted, !player.isPlaying {
                stoppedChecks += 1
                if stoppedChecks >= 6, stableSizeChecks >= 4 { break }
            } else {
                stoppedChecks = 0
            }

            if !hasStarted, Date().timeIntervalSince(startedAt) > 45 {
                player.stop()
                try? FileManager.default.removeItem(at: outputURL)
                throw DownloadError.vlcFailed("Could not open the HLS link")
            }
        }

        player.stop()
        let finalAttributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let finalSize = (finalAttributes?[.size] as? NSNumber)?.uint64Value ?? 0
        guard finalSize > 10_000 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw DownloadError.vlcFailed("No valid MP4 file was produced")
        }
        onProgress(Progress(downloadedSegments: 1000, totalSegments: 1000, bytesWritten: Int64(clamping: finalSize), totalBytesExpected: Int64(clamping: finalSize)))
        return outputURL
    }

    private static func headerValue(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
    private static func remux(sourceFile: URL, to mp4URL: URL) async throws {
        let asset = AVURLAsset(url: sourceFile)
        let tracks = try await asset.load(.tracks)
        guard !tracks.isEmpty else {
            throw DownloadError.exportFailed("No valid video or audio tracks were found after download")
        }
        let duration = try await asset.load(.duration)
        guard duration.isValid, duration.seconds.isFinite, duration.seconds > 0 else {
            // The .ts container parses enough to report tracks, but has no
            // usable timeline — a strong sign the concatenated segments have
            // PTS/DTS discontinuities or are encrypted, not a codec/preset issue.
            throw DownloadError.exportFailed("The merged video stream is invalid or has an unknown duration")
        }

        // Passthrough is fast (no re-encode) but only works when every track's
        // exact format is directly mp4-compatible. Some sources (odd audio
        // codecs, HEVC without the right profile, discontinuities between
        // segments) fail passthrough — HighestQuality re-encodes from
        // scratch and is far more tolerant, at the cost of time/battery.
        let presets = [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
        var lastError: Error?
        for preset in presets {
            guard let export = AVAssetExportSession(asset: asset, presetName: preset),
                  export.supportedFileTypes.contains(.mp4) else { continue }
            try? FileManager.default.removeItem(at: mp4URL)
            export.outputURL = mp4URL
            export.outputFileType = .mp4
            export.shouldOptimizeForNetworkUse = true
            await export.export()
            if export.status == .completed {
                return
            }
            lastError = export.error
            try? FileManager.default.removeItem(at: mp4URL)
        }
        if let nsError = lastError as NSError? {
            throw DownloadError.exportFailed("\(nsError.localizedDescription) [\(nsError.domain) #\(nsError.code)]")
        }
        throw DownloadError.exportFailed("unknown")
    }

    private static func fetchText(_ url: URL, headers: [String: String]) async throws -> String {
        let (data, response) = try await performRequest(url: url, headers: headers, acceptsPlaylist: true)
        try checkAuth(response)
        guard let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U") else {
            throw DownloadError.invalidPlaylist
        }
        return text
    }

    private static func fetchData(_ url: URL, headers: [String: String]) async throws -> Data {
        let (data, response) = try await performRequest(url: url, headers: headers, acceptsPlaylist: false)
        try checkAuth(response)
        return data
    }

    private static func performRequest(
        url: URL,
        headers: [String: String],
        acceptsPlaylist: Bool
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.httpShouldHandleCookies = true

        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(
                "AppleCoreMedia/1.0.0.21F90 (iPhone; U; CPU OS 17_5 like Mac OS X; en_us)",
                forHTTPHeaderField: "User-Agent"
            )
        }
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue(
                "*/*",
                forHTTPHeaderField: "Accept"
            )
        }
        if request.value(forHTTPHeaderField: "Accept-Language") == nil {
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        // URLSession normally applies shared cookies, but explicitly attaching
        // them also covers cookies created by the in-app web login/browser.
        if request.value(forHTTPHeaderField: "Cookie") == nil,
           let cookies = HTTPCookieStorage.shared.cookies(for: url),
           !cookies.isEmpty,
           let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        let firstResult = try await HighPriorityNetworkManager.shared.videoData(for: request)
        if let response = firstResult.1 as? HTTPURLResponse, response.statusCode == 471 {
            // Some CDNs accept browser-style HLS requests but reject the
            // AppleCoreMedia identity (or the reverse). Retry exactly once
            // with Mobile Safari while keeping the signature and cookies.
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            return try await HighPriorityNetworkManager.shared.videoData(for: request)
        }
        return firstResult
    }

    private static func checkAuth(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw URLError(.userAuthenticationRequired)
        }
        guard (200...299).contains(http.statusCode) else {
            throw DownloadError.exportFailed("HTTP \(http.statusCode)")
        }
    }

    /// If the given playlist is a master playlist (lists variant streams),
    /// pick the highest-bandwidth variant and return its resolved URL.
    /// Otherwise the given URL already points at a media (segment) playlist.
    private static func resolveMediaPlaylistURL(masterURL: URL, masterPlaylistText: String) throws -> URL {
        let lines = masterPlaylistText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var bestBandwidth = -1
        var bestURI: String?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                let bandwidth = extractInt(from: line, key: "BANDWIDTH") ?? 0
                if index + 1 < lines.count {
                    let uriLine = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !uriLine.isEmpty, !uriLine.hasPrefix("#"), bandwidth > bestBandwidth {
                        bestBandwidth = bandwidth
                        bestURI = uriLine
                    }
                }
            }
            index += 1
        }
        guard let uri = bestURI else {
            // No variant streams found — this is already a media playlist.
            return masterURL
        }
        return resolve(uri: uri, relativeTo: masterURL)
    }

    private static func parseSegmentURLs(playlistText: String, baseURL: URL) throws -> [URL] {
        let lines = playlistText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var urls: [URL] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            urls.append(resolve(uri: trimmed, relativeTo: baseURL))
        }
        return urls
    }

    private static func parseInitializationURL(playlistText: String, baseURL: URL) -> URL? {
        for rawLine in playlistText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#EXT-X-MAP:"),
                  let uriRange = line.range(of: #"URI="([^"]+)""#, options: .regularExpression) else { continue }
            let value = String(line[uriRange]).dropFirst(5).dropLast()
            return resolve(uri: String(value), relativeTo: baseURL)
        }
        return nil
    }

    private static func resolve(uri: String, relativeTo base: URL) -> URL {
        let resolved: URL
        if let absolute = URL(string: uri), absolute.scheme != nil {
            resolved = absolute
        } else if let relative = URL(string: uri, relativeTo: base)?.absoluteURL {
            resolved = relative
        } else {
            return base
        }

        // Signed HLS URLs commonly put the authorization query only on the
        // master URL. URL's normal relative resolution drops that query, so
        // explicitly inherit it when the child URI does not provide its own.
        guard let baseComponents = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let inheritedItems = baseComponents.queryItems,
              !inheritedItems.isEmpty,
              var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else {
            return resolved
        }
        var childItems = components.queryItems ?? []
        let childNames = Set(childItems.map(\.name))
        childItems.append(contentsOf: inheritedItems.filter { !childNames.contains($0.name) })
        components.queryItems = childItems
        return components.url ?? resolved
    }

    private static func extractInt(from line: String, key: String) -> Int? {
        guard let range = line.range(of: "\(key)=") else { return nil }
        let rest = line[range.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        return Int(digits)
    }
}
