import Foundation

struct MatroskaSubtitleCue: Sendable, Equatable {
    let start: Double
    let end: Double
    let text: String
}

struct MatroskaTextSubtitleTrack: Identifiable, Sendable, Equatable {
    let id: String
    let trackNumber: UInt64
    let title: String
    let languageCode: String?
    let isDefault: Bool
    let isForced: Bool
    let cues: [MatroskaSubtitleCue]
}

enum MatroskaSubtitleExtractorError: LocalizedError {
    case invalidContainer
    case missingTracks
    case rangeRequestsUnsupported
    case oversizedElement

    var errorDescription: String? {
        switch self {
        case .invalidContainer: return "This file is not a readable Matroska container."
        case .missingTracks: return "No supported text subtitle tracks were found."
        case .rangeRequestsUnsupported: return "The video server does not support byte-range reads."
        case .oversizedElement: return "The Matroska subtitle index is unexpectedly large."
        }
    }
}

/// Reads text subtitles directly from a Matroska container. VLC is deliberately
/// not involved: text tracks are decoded into timed cues for the player's fixed
/// SwiftUI subtitle overlay.
enum MatroskaSubtitleExtractor {
    static func extract(from url: URL, httpHeaders: [String: String]? = nil) async throws -> [MatroskaTextSubtitleTrack] {
        let source = MatroskaByteSource(url: url, headers: httpHeaders ?? [:])
        let fileSize = try await source.fileSize()
        let initialCount = Int(min(fileSize, 8 * 1_024 * 1_024))
        let initial = try await source.read(offset: 0, count: initialCount)
        let metadata = try parseMetadata(initial)

        var resolvedMetadata = metadata
        if resolvedMetadata.info == nil, let position = metadata.seekPositions[MatroskaID.info] {
            let data = try await readElement(at: metadata.segmentContentOffset + position, from: source, maximumSize: 2 * 1_024 * 1_024)
            resolvedMetadata.info = parseInfo(data)
        }
        if resolvedMetadata.tracks.isEmpty, let position = metadata.seekPositions[MatroskaID.tracks] {
            let data = try await readElement(at: metadata.segmentContentOffset + position, from: source, maximumSize: 8 * 1_024 * 1_024)
            resolvedMetadata.tracks = parseTracks(data)
        }

        let textTracks = resolvedMetadata.tracks.filter { $0.isSupportedTextSubtitle }
        guard !textTracks.isEmpty else { throw MatroskaSubtitleExtractorError.missingTracks }

        let cueData = try await locateCues(metadata: resolvedMetadata, source: source, fileSize: fileSize)
        let scale = resolvedMetadata.info?.timecodeScale ?? 1_000_000
        let references = cueData.map { parseCueReferences($0, timecodeScale: scale) } ?? []

        var output: [MatroskaTextSubtitleTrack] = []
        for track in textTracks {
            try Task.checkCancellation()
            let trackReferences = references.filter { $0.trackNumber == track.number }
            var cues = try await extractIndexedCues(
                track: track,
                references: trackReferences,
                segmentContentOffset: resolvedMetadata.segmentContentOffset,
                timecodeScale: scale,
                source: source
            )

            // Older/local MKVs sometimes omit subtitle entries from Cues.
            // A local file is cheap to scan without touching video payloads;
            // remote files intentionally avoid a full download.
            if cues.isEmpty, url.isFileURL {
                cues = try await scanLocalClusters(
                    track: track,
                    metadata: resolvedMetadata,
                    timecodeScale: scale,
                    source: source,
                    fileSize: fileSize
                )
            }
            guard !cues.isEmpty else { continue }

            output.append(MatroskaTextSubtitleTrack(
                id: "mkv-text:\(track.number)",
                trackNumber: track.number,
                title: displayTitle(for: track),
                languageCode: track.language,
                isDefault: track.isDefault,
                isForced: track.isForced,
                cues: normalizeCueEnds(cues)
            ))
        }

        guard !output.isEmpty else { throw MatroskaSubtitleExtractorError.missingTracks }
        return output
    }
}

// MARK: - Matroska metadata

private enum MatroskaID {
    static let segment: UInt64 = 0x18538067
    static let seekHead: UInt64 = 0x114D9B74
    static let seek: UInt64 = 0x4DBB
    static let seekID: UInt64 = 0x53AB
    static let seekPosition: UInt64 = 0x53AC
    static let info: UInt64 = 0x1549A966
    static let timecodeScale: UInt64 = 0x2AD7B1
    static let tracks: UInt64 = 0x1654AE6B
    static let trackEntry: UInt64 = 0xAE
    static let trackNumber: UInt64 = 0xD7
    static let trackType: UInt64 = 0x83
    static let flagDefault: UInt64 = 0x88
    static let flagForced: UInt64 = 0x55AA
    static let trackName: UInt64 = 0x536E
    static let language: UInt64 = 0x22B59C
    static let languageIETF: UInt64 = 0x22B59D
    static let codecID: UInt64 = 0x86
    static let cues: UInt64 = 0x1C53BB6B
    static let cuePoint: UInt64 = 0xBB
    static let cueTime: UInt64 = 0xB3
    static let cueTrackPositions: UInt64 = 0xB7
    static let cueTrack: UInt64 = 0xF7
    static let cueClusterPosition: UInt64 = 0xF1
    static let cueRelativePosition: UInt64 = 0xF0
    static let cueDuration: UInt64 = 0xB2
    static let cluster: UInt64 = 0x1F43B675
    static let clusterTimecode: UInt64 = 0xE7
    static let simpleBlock: UInt64 = 0xA3
    static let blockGroup: UInt64 = 0xA0
    static let block: UInt64 = 0xA1
    static let blockDuration: UInt64 = 0x9B
}

private struct MatroskaElement {
    let id: UInt64
    let offset: Int
    let headerSize: Int
    let payloadSize: UInt64?

    var contentOffset: Int { offset + headerSize }
    var totalSize: UInt64? { payloadSize.map { UInt64(headerSize) + $0 } }
}

private struct MatroskaInfo {
    var timecodeScale: UInt64 = 1_000_000
}

private struct MatroskaTrack: Sendable {
    var number: UInt64 = 0
    var type: UInt64 = 0
    var codecID = ""
    var name: String?
    var language: String?
    var isDefault = true
    var isForced = false

    var isSupportedTextSubtitle: Bool {
        guard type == 17 else { return false }
        return ["S_TEXT/UTF8", "S_TEXT/ASCII", "S_TEXT/ASS", "S_TEXT/SSA", "S_TEXT/WEBVTT"].contains(codecID.uppercased())
    }
}

private struct MatroskaMetadata {
    var segmentContentOffset: UInt64
    var segmentPayloadSize: UInt64?
    var seekPositions: [UInt64: UInt64]
    var info: MatroskaInfo?
    var tracks: [MatroskaTrack]
}

private struct MatroskaCueReference: Sendable {
    let trackNumber: UInt64
    let start: Double
    let duration: Double?
    let clusterPosition: UInt64
    let relativePosition: UInt64?
}

private struct DecodedBlock {
    let trackNumber: UInt64
    let relativeTimecode: Int16
    let frames: [Data]
}

private func parseMetadata(_ data: Data) throws -> MatroskaMetadata {
    var cursor = 0
    var segment: MatroskaElement?
    while cursor < data.count, let element = parseElementHeader(data, at: cursor) {
        if element.id == MatroskaID.segment {
            segment = element
            break
        }
        guard let total = element.totalSize, total > 0, total <= UInt64(Int.max) else { break }
        cursor += Int(total)
    }
    guard let segment else { throw MatroskaSubtitleExtractorError.invalidContainer }

    var metadata = MatroskaMetadata(
        segmentContentOffset: UInt64(segment.contentOffset),
        segmentPayloadSize: segment.payloadSize,
        seekPositions: [:],
        info: nil,
        tracks: []
    )
    cursor = segment.contentOffset
    while cursor < data.count, let element = parseElementHeader(data, at: cursor) {
        guard let total = element.totalSize, total > 0, total <= UInt64(Int.max) else { break }
        let end = cursor + Int(total)
        guard end <= data.count else { break }
        switch element.id {
        case MatroskaID.seekHead:
            metadata.seekPositions.merge(parseSeekHead(data, element: element)) { current, _ in current }
        case MatroskaID.info:
            metadata.info = parseInfo(Data(data[cursor..<end]))
        case MatroskaID.tracks:
            metadata.tracks = parseTracks(Data(data[cursor..<end]))
        default:
            break
        }
        // Cluster payloads dominate the file; metadata and SeekHead precede them.
        if element.id == MatroskaID.cluster { break }
        cursor = end
    }
    return metadata
}

private func parseSeekHead(_ data: Data, element: MatroskaElement) -> [UInt64: UInt64] {
    var positions: [UInt64: UInt64] = [:]
    for seek in childElements(data, parent: element) where seek.id == MatroskaID.seek {
        var targetID: UInt64?
        var targetPosition: UInt64?
        for child in childElements(data, parent: seek) {
            if child.id == MatroskaID.seekID { targetID = unsignedInteger(data, element: child) }
            if child.id == MatroskaID.seekPosition { targetPosition = unsignedInteger(data, element: child) }
        }
        if let targetID, let targetPosition { positions[targetID] = targetPosition }
    }
    return positions
}

private func parseInfo(_ data: Data) -> MatroskaInfo? {
    guard let root = parseElementHeader(data, at: 0), root.id == MatroskaID.info else { return nil }
    var info = MatroskaInfo()
    for child in childElements(data, parent: root) where child.id == MatroskaID.timecodeScale {
        info.timecodeScale = unsignedInteger(data, element: child) ?? info.timecodeScale
    }
    return info
}

private func parseTracks(_ data: Data) -> [MatroskaTrack] {
    guard let root = parseElementHeader(data, at: 0), root.id == MatroskaID.tracks else { return [] }
    return childElements(data, parent: root).compactMap { entry in
        guard entry.id == MatroskaID.trackEntry else { return nil }
        var track = MatroskaTrack()
        for child in childElements(data, parent: entry) {
            switch child.id {
            case MatroskaID.trackNumber: track.number = unsignedInteger(data, element: child) ?? 0
            case MatroskaID.trackType: track.type = unsignedInteger(data, element: child) ?? 0
            case MatroskaID.flagDefault: track.isDefault = (unsignedInteger(data, element: child) ?? 1) != 0
            case MatroskaID.flagForced: track.isForced = (unsignedInteger(data, element: child) ?? 0) != 0
            case MatroskaID.trackName: track.name = utf8String(data, element: child)
            case MatroskaID.languageIETF: track.language = utf8String(data, element: child)
            case MatroskaID.language where track.language == nil: track.language = utf8String(data, element: child)
            case MatroskaID.codecID: track.codecID = utf8String(data, element: child) ?? ""
            default: break
            }
        }
        return track.number > 0 ? track : nil
    }
}

private func parseCueReferences(_ data: Data, timecodeScale: UInt64) -> [MatroskaCueReference] {
    guard let root = parseElementHeader(data, at: 0), root.id == MatroskaID.cues else { return [] }
    var result: [MatroskaCueReference] = []
    for point in childElements(data, parent: root) where point.id == MatroskaID.cuePoint {
        let children = childElements(data, parent: point)
        guard let timeElement = children.first(where: { $0.id == MatroskaID.cueTime }),
              let ticks = unsignedInteger(data, element: timeElement) else { continue }
        let start = seconds(ticks: ticks, scale: timecodeScale)
        for positions in children where positions.id == MatroskaID.cueTrackPositions {
            var track: UInt64?
            var cluster: UInt64?
            var relative: UInt64?
            var duration: UInt64?
            for child in childElements(data, parent: positions) {
                switch child.id {
                case MatroskaID.cueTrack: track = unsignedInteger(data, element: child)
                case MatroskaID.cueClusterPosition: cluster = unsignedInteger(data, element: child)
                case MatroskaID.cueRelativePosition: relative = unsignedInteger(data, element: child)
                case MatroskaID.cueDuration: duration = unsignedInteger(data, element: child)
                default: break
                }
            }
            if let track, let cluster {
                result.append(MatroskaCueReference(
                    trackNumber: track,
                    start: start,
                    duration: duration.map { seconds(ticks: $0, scale: timecodeScale) },
                    clusterPosition: cluster,
                    relativePosition: relative
                ))
            }
        }
    }
    return result
}

// MARK: - Cue extraction

private func locateCues(metadata: MatroskaMetadata, source: MatroskaByteSource, fileSize: UInt64) async throws -> Data? {
    if let position = metadata.seekPositions[MatroskaID.cues] {
        return try await readElement(
            at: metadata.segmentContentOffset + position,
            from: source,
            maximumSize: 64 * 1_024 * 1_024
        )
    }

    // Some muxers omit SeekHead. Cues are conventionally near the end, so a
    // bounded tail search still avoids downloading the media payload.
    let tailCount = Int(min(fileSize, 16 * 1_024 * 1_024))
    let tailOffset = fileSize - UInt64(tailCount)
    let tail = try await source.read(offset: tailOffset, count: tailCount)
    let signature = Data([0x1C, 0x53, 0xBB, 0x6B])
    guard let match = tail.range(of: signature, options: .backwards) else { return nil }
    let absolute = tailOffset + UInt64(match.lowerBound)
    return try? await readElement(at: absolute, from: source, maximumSize: 64 * 1_024 * 1_024)
}

private func extractIndexedCues(
    track: MatroskaTrack,
    references: [MatroskaCueReference],
    segmentContentOffset: UInt64,
    timecodeScale: UInt64,
    source: MatroskaByteSource
) async throws -> [MatroskaSubtitleCue] {
    guard !references.isEmpty else { return [] }
    let ordered = references.sorted { $0.start < $1.start }
    var indexed: [(Int, MatroskaSubtitleCue)] = []

    // Bound concurrency so a long movie does not flood a remote WebDAV/CDN.
    for batchStart in stride(from: 0, to: ordered.count, by: 12) {
        try Task.checkCancellation()
        let batchEnd = min(ordered.count, batchStart + 12)
        let batch = Array(ordered[batchStart..<batchEnd])
        let values = try await withThrowingTaskGroup(of: (Int, MatroskaSubtitleCue?).self) { group in
            for (localIndex, reference) in batch.enumerated() {
                let absoluteIndex = batchStart + localIndex
                group.addTask {
                    do {
                        let cue = try await decodeIndexedCue(
                            track: track,
                            reference: reference,
                            segmentContentOffset: segmentContentOffset,
                            timecodeScale: timecodeScale,
                            source: source
                        )
                        return (absoluteIndex, cue)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // One corrupt/missing cue must not hide the rest of a
                        // valid subtitle track.
                        return (absoluteIndex, nil)
                    }
                }
            }
            var result: [(Int, MatroskaSubtitleCue?)] = []
            for try await value in group { result.append(value) }
            return result
        }
        indexed.append(contentsOf: values.compactMap { index, cue in cue.map { (index, $0) } })
    }
    return indexed.sorted { $0.0 < $1.0 }.map(\.1)
}

private func decodeIndexedCue(
    track: MatroskaTrack,
    reference: MatroskaCueReference,
    segmentContentOffset: UInt64,
    timecodeScale: UInt64,
    source: MatroskaByteSource
) async throws -> MatroskaSubtitleCue? {
    let clusterOffset = segmentContentOffset + reference.clusterPosition
    let clusterHeaderData = try await source.read(offset: clusterOffset, count: 16)
    guard let cluster = parseElementHeader(clusterHeaderData, at: 0), cluster.id == MatroskaID.cluster else { return nil }
    guard let relative = reference.relativePosition else { return nil }
    let blockOffset = clusterOffset + UInt64(cluster.headerSize) + relative
    let elementData = try await readElement(at: blockOffset, from: source, maximumSize: 1 * 1_024 * 1_024)
    guard let element = parseElementHeader(elementData, at: 0) else { return nil }

    var block: DecodedBlock?
    var blockDuration: Double?
    if element.id == MatroskaID.simpleBlock {
        block = decodeBlock(payload(elementData, element: element))
    } else if element.id == MatroskaID.blockGroup {
        for child in childElements(elementData, parent: element) {
            if child.id == MatroskaID.block { block = decodeBlock(payload(elementData, element: child)) }
            if child.id == MatroskaID.blockDuration, let ticks = unsignedInteger(elementData, element: child) {
                blockDuration = seconds(ticks: ticks, scale: timecodeScale)
            }
        }
    }
    guard let block, block.trackNumber == track.number else { return nil }
    let text = block.frames.compactMap { decodeSubtitleText($0, codecID: track.codecID) }.joined(separator: "\n")
    guard !text.isEmpty else { return nil }
    let duration = reference.duration ?? blockDuration ?? 0
    return MatroskaSubtitleCue(start: reference.start, end: reference.start + max(0.01, duration), text: text)
}

private func scanLocalClusters(
    track: MatroskaTrack,
    metadata: MatroskaMetadata,
    timecodeScale: UInt64,
    source: MatroskaByteSource,
    fileSize: UInt64
) async throws -> [MatroskaSubtitleCue] {
    let segmentEnd = metadata.segmentPayloadSize.map { min(fileSize, metadata.segmentContentOffset + $0) } ?? fileSize
    var topOffset = metadata.segmentContentOffset
    var cues: [MatroskaSubtitleCue] = []
    while topOffset + 2 < segmentEnd {
        try Task.checkCancellation()
        guard let header = try await readHeader(at: topOffset, from: source),
              let total = header.totalSize, total > 0 else { break }
        if header.id == MatroskaID.cluster, let payloadSize = header.payloadSize {
            let clusterEnd = min(segmentEnd, topOffset + UInt64(header.headerSize) + payloadSize)
            var childOffset = topOffset + UInt64(header.headerSize)
            var clusterTimecode: UInt64 = 0
            while childOffset + 2 < clusterEnd {
                guard let child = try await readHeader(at: childOffset, from: source),
                      let childTotal = child.totalSize, childTotal > 0 else { break }
                if child.id == MatroskaID.clusterTimecode {
                    let data = try await source.read(offset: childOffset, count: Int(childTotal))
                    if let local = parseElementHeader(data, at: 0) { clusterTimecode = unsignedInteger(data, element: local) ?? 0 }
                } else if child.id == MatroskaID.simpleBlock || child.id == MatroskaID.blockGroup {
                    let prefixCount = Int(min(childTotal, 512))
                    let prefix = try await source.read(offset: childOffset, count: prefixCount)
                    if blockTrackNumber(in: prefix) == track.number {
                        let full = try await source.read(offset: childOffset, count: Int(childTotal))
                        if let cue = decodeScannedElement(full, track: track, clusterTimecode: clusterTimecode, scale: timecodeScale) {
                            cues.append(cue)
                        }
                    }
                }
                childOffset += childTotal
            }
        }
        topOffset += total
    }
    return cues.sorted { $0.start < $1.start }
}

private func blockTrackNumber(in data: Data) -> UInt64? {
    guard let root = parseElementHeader(data, at: 0) else { return nil }
    if root.id == MatroskaID.simpleBlock {
        return decodeBlock(payload(data, element: root))?.trackNumber
    }
    if root.id == MatroskaID.blockGroup {
        var cursor = root.contentOffset
        while cursor < data.count, let child = parseElementHeader(data, at: cursor) {
            if child.id == MatroskaID.block {
                // The prefix may intentionally contain only the beginning of
                // a large block. Track number/timecode live at its front.
                guard child.contentOffset < data.count else { return nil }
                return decodeBlock(Data(data[child.contentOffset..<data.count]))?.trackNumber
            }
            guard let total = child.totalSize, total > 0, total <= UInt64(Int.max) else { break }
            let next = cursor + Int(total)
            guard next <= data.count else { break }
            cursor = next
        }
    }
    return nil
}

private func decodeScannedElement(_ data: Data, track: MatroskaTrack, clusterTimecode: UInt64, scale: UInt64) -> MatroskaSubtitleCue? {
    guard let root = parseElementHeader(data, at: 0) else { return nil }
    var block: DecodedBlock?
    var duration: Double?
    if root.id == MatroskaID.simpleBlock {
        block = decodeBlock(payload(data, element: root))
    } else if root.id == MatroskaID.blockGroup {
        for child in childElements(data, parent: root) {
            if child.id == MatroskaID.block { block = decodeBlock(payload(data, element: child)) }
            if child.id == MatroskaID.blockDuration, let ticks = unsignedInteger(data, element: child) {
                duration = seconds(ticks: ticks, scale: scale)
            }
        }
    }
    guard let block, block.trackNumber == track.number else { return nil }
    let absoluteTicks = max(0, Int64(clusterTimecode) + Int64(block.relativeTimecode))
    let start = seconds(ticks: UInt64(absoluteTicks), scale: scale)
    let text = block.frames.compactMap { decodeSubtitleText($0, codecID: track.codecID) }.joined(separator: "\n")
    guard !text.isEmpty else { return nil }
    return MatroskaSubtitleCue(start: start, end: start + max(0.01, duration ?? 0), text: text)
}

// MARK: - Block/text decoding

private func decodeBlock(_ data: Data) -> DecodedBlock? {
    guard let trackVINT = parseVINT(data, at: 0, removingMarker: true),
          data.count >= trackVINT.length + 3 else { return nil }
    let timeOffset = trackVINT.length
    let rawTime = (UInt16(data[timeOffset]) << 8) | UInt16(data[timeOffset + 1])
    let relativeTime = Int16(bitPattern: rawTime)
    let flags = data[timeOffset + 2]
    let frameOffset = timeOffset + 3
    let lacing = (flags & 0x06) >> 1
    guard lacing == 0 else { return nil } // Subtitle blocks are not normally laced.
    return DecodedBlock(
        trackNumber: trackVINT.value,
        relativeTimecode: relativeTime,
        frames: [Data(data[frameOffset..<data.count])]
    )
}

private func decodeSubtitleText(_ data: Data, codecID: String) -> String? {
    guard var text = String(data: data, encoding: .utf8) else { return nil }
    let codec = codecID.uppercased()
    if codec == "S_TEXT/ASS" || codec == "S_TEXT/SSA" {
        // Matroska ASS packets omit Start/End and begin with ReadOrder. The
        // ninth comma-separated field is the actual dialogue text.
        var commaCount = 0
        var textStart = text.startIndex
        for index in text.indices where text[index] == "," {
            commaCount += 1
            if commaCount == 8 {
                textStart = text.index(after: index)
                break
            }
        }
        if commaCount >= 8 { text = String(text[textStart...]) }
        text = text
            .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\N"#, with: "\n")
            .replacingOccurrences(of: #"\n"#, with: "\n")
            .replacingOccurrences(of: #"\h"#, with: " ")
    }
    text = text
        .replacingOccurrences(of: "\0", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}

private func normalizeCueEnds(_ cues: [MatroskaSubtitleCue]) -> [MatroskaSubtitleCue] {
    let ordered = cues.sorted { lhs, rhs in lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start }
    var result: [MatroskaSubtitleCue] = []
    for (index, cue) in ordered.enumerated() {
        let nextStart = index + 1 < ordered.count ? ordered[index + 1].start : nil
        var end = cue.end
        if end <= cue.start + 0.05 {
            end = nextStart.map { max(cue.start + 0.05, $0 - 0.001) } ?? (cue.start + 4)
        }
        result.append(MatroskaSubtitleCue(start: cue.start, end: end, text: cue.text))
    }
    return result
}

private func displayTitle(for track: MatroskaTrack) -> String {
    var title = track.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if title.isEmpty {
        if let language = track.language, !language.isEmpty {
            title = Locale.current.localizedString(forLanguageCode: language) ?? language.uppercased()
        } else {
            title = "Subtitle \(track.number)"
        }
    }
    if track.isForced && !title.lowercased().contains("forced") { title += " · Forced" }
    return title
}

private func seconds(ticks: UInt64, scale: UInt64) -> Double {
    Double(ticks) * Double(scale) / 1_000_000_000
}

// MARK: - EBML helpers

private func parseElementHeader(_ data: Data, at offset: Int) -> MatroskaElement? {
    guard offset >= 0, offset < data.count,
          let id = parseVINT(data, at: offset, removingMarker: false),
          let size = parseVINT(data, at: offset + id.length, removingMarker: true) else { return nil }
    let unknownMask = size.length == 8 ? UInt64.max >> 8 : (UInt64(1) << UInt64(7 * size.length)) - 1
    let payloadSize: UInt64? = size.value == unknownMask ? nil : size.value
    return MatroskaElement(id: id.value, offset: offset, headerSize: id.length + size.length, payloadSize: payloadSize)
}

private func parseVINT(_ data: Data, at offset: Int, removingMarker: Bool) -> (value: UInt64, length: Int)? {
    guard offset >= 0, offset < data.count else { return nil }
    let first = data[offset]
    guard first != 0 else { return nil }
    var mask: UInt8 = 0x80
    var length = 1
    while length <= 8, first & mask == 0 { mask >>= 1; length += 1 }
    guard length <= 8, offset + length <= data.count else { return nil }
    var value = UInt64(removingMarker ? first & ~mask : first)
    if length > 1 {
        for index in 1..<length { value = (value << 8) | UInt64(data[offset + index]) }
    }
    return (value, length)
}

private func childElements(_ data: Data, parent: MatroskaElement) -> [MatroskaElement] {
    guard let payloadSize = parent.payloadSize,
          payloadSize <= UInt64(Int.max) else { return [] }
    let declaredEnd = parent.contentOffset + Int(payloadSize)
    let end = min(data.count, declaredEnd)
    var cursor = parent.contentOffset
    var result: [MatroskaElement] = []
    while cursor < end, let child = parseElementHeader(data, at: cursor) {
        guard let total = child.totalSize, total > 0, total <= UInt64(Int.max) else { break }
        let next = cursor + Int(total)
        guard next <= end else { break }
        result.append(child)
        cursor = next
    }
    return result
}

private func payload(_ data: Data, element: MatroskaElement) -> Data {
    guard let size = element.payloadSize, size <= UInt64(Int.max) else { return Data() }
    let end = min(data.count, element.contentOffset + Int(size))
    guard element.contentOffset <= end else { return Data() }
    return Data(data[element.contentOffset..<end])
}

private func unsignedInteger(_ data: Data, element: MatroskaElement) -> UInt64? {
    let bytes = payload(data, element: element)
    guard !bytes.isEmpty, bytes.count <= 8 else { return nil }
    return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
}

private func utf8String(_ data: Data, element: MatroskaElement) -> String? {
    String(data: payload(data, element: element), encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
}

private func readHeader(at offset: UInt64, from source: MatroskaByteSource) async throws -> MatroskaElement? {
    let data = try await source.read(offset: offset, count: 16)
    return parseElementHeader(data, at: 0)
}

private func readElement(at offset: UInt64, from source: MatroskaByteSource, maximumSize: Int) async throws -> Data {
    let prefix = try await source.read(offset: offset, count: 16)
    guard let element = parseElementHeader(prefix, at: 0), let total = element.totalSize else {
        throw MatroskaSubtitleExtractorError.invalidContainer
    }
    guard total <= UInt64(maximumSize), total <= UInt64(Int.max) else {
        throw MatroskaSubtitleExtractorError.oversizedElement
    }
    return try await source.read(offset: offset, count: Int(total))
}

// MARK: - Local/HTTP range source

private final class MatroskaByteSource: @unchecked Sendable {
    let url: URL
    let headers: [String: String]

    init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }

    func fileSize() async throws -> UInt64 {
        let size: UInt64
        if url.isFileURL {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            size = UInt64(values.fileSize ?? 0)
        } else {
            var head = URLRequest(url: url)
            head.httpMethod = "HEAD"
            head.timeoutInterval = 20
            for (name, value) in headers where name.caseInsensitiveCompare("Range") != .orderedSame {
                head.setValue(value, forHTTPHeaderField: name)
            }
            let (_, headResponse) = try await HighPriorityNetworkManager.shared.responsiveData(for: head)
            if let http = headResponse as? HTTPURLResponse,
               (200...299).contains(http.statusCode),
               headResponse.expectedContentLength > 0 {
                size = UInt64(headResponse.expectedContentLength)
            } else {
                var request = requestForRange(offset: 0, count: 1)
                request.timeoutInterval = 30
                let (_, response) = try await HighPriorityNetworkManager.shared.responsiveData(for: request)
                guard let http = response as? HTTPURLResponse,
                      let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                      let slash = contentRange.lastIndex(of: "/"),
                      let parsed = UInt64(contentRange[contentRange.index(after: slash)...]) else {
                    throw MatroskaSubtitleExtractorError.rangeRequestsUnsupported
                }
                size = parsed
            }
        }
        guard size > 0 else { throw MatroskaSubtitleExtractorError.invalidContainer }
        return size
    }

    func read(offset: UInt64, count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        if url.isFileURL {
            return try await Task.detached(priority: .utility) { [url] in
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: offset)
                return try handle.read(upToCount: count) ?? Data()
            }.value
        }

        var request = requestForRange(offset: offset, count: count)
        request.timeoutInterval = 45
        let (data, response) = try await HighPriorityNetworkManager.shared.responsiveData(for: request)
        guard let http = response as? HTTPURLResponse else { throw MatroskaSubtitleExtractorError.rangeRequestsUnsupported }
        if http.statusCode == 206 { return data }
        // A 200 response is only safe for an initial read. Accept its prefix;
        // all random-access reads must be backed by actual HTTP range support.
        if http.statusCode == 200, offset == 0 { return Data(data.prefix(count)) }
        throw MatroskaSubtitleExtractorError.rangeRequestsUnsupported
    }

    private func requestForRange(offset: UInt64, count: Int) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (name, value) in headers where name.caseInsensitiveCompare("Range") != .orderedSame {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let end = offset + UInt64(max(0, count - 1))
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }
}
