import Foundation
import Compression

struct MatroskaSubtitleCue: Sendable, Equatable {
    let start: Double
    let end: Double
    let text: String
}

struct MatroskaTextSubtitleTrack: Identifiable, Sendable, Equatable {
    let id: String
    let trackNumber: UInt64
    /// Zero-based position among every subtitle track in container order.
    /// VLC exposes its subtitle list in the same order, including PGS/VobSub.
    let containerSubtitleIndex: Int
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
    static func extract(
        from url: URL,
        httpHeaders: [String: String]? = nil,
        subtitleIndices: Set<Int>? = nil,
        preferredTrackOnly: Bool = false,
        priorityTime: Double? = nil,
        onTrackExtracted: (@MainActor (MatroskaTextSubtitleTrack) -> Void)? = nil
    ) async throws -> [MatroskaTextSubtitleTrack] {
        let source = MatroskaByteSource(url: url, headers: httpHeaders ?? [:])
        let fileSize = try await source.fileSize()
        // Tracks/SeekHead live at the front of normal Matroska files (the
        // supplied 2.3 GB PikPak sample stores them around byte 4 KB). One MB
        // is ample for the front index while avoiding an unnecessary 8 MB
        // transfer competing with playback startup.
        let initialCount = Int(min(fileSize, 1 * 1_024 * 1_024))
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

        // Preserve container order so VLC's selected-track index maps to the
        // same extracted text track while tracks arrive incrementally.
        let availableTextTracks = resolvedMetadata.tracks
            .filter { $0.type == 17 }
            .enumerated()
            .compactMap { subtitleIndex, track in
                track.isSupportedTextSubtitle ? (subtitleIndex, track) : nil
            }
        let textTracks: [(Int, MatroskaTrack)]
        if let subtitleIndices {
            textTracks = availableTextTracks.filter { subtitleIndices.contains($0.0) }
        } else if preferredTrackOnly {
            let preferred = availableTextTracks.first(where: { $0.1.isForced })
                ?? availableTextTracks.first(where: { $0.1.isDefault })
                ?? availableTextTracks.first
            textTracks = preferred.map { [$0] } ?? []
        } else {
            textTracks = availableTextTracks
        }
        guard !textTracks.isEmpty else { throw MatroskaSubtitleExtractorError.missingTracks }

        let cueData = try await locateCues(metadata: resolvedMetadata, source: source, fileSize: fileSize)
        let scale = resolvedMetadata.info?.timecodeScale ?? 1_000_000
        let references = cueData.map { parseCueReferences($0, timecodeScale: scale) } ?? []

        var output: [MatroskaTextSubtitleTrack] = []
        for (subtitleIndex, track) in textTracks {
            try Task.checkCancellation()
            let trackReferences = references.filter { $0.trackNumber == track.number }
            let makeExtractedTrack: ([MatroskaSubtitleCue]) -> MatroskaTextSubtitleTrack = { cues in
                MatroskaTextSubtitleTrack(
                    id: "mkv-text:\(track.number)",
                    trackNumber: track.number,
                    containerSubtitleIndex: subtitleIndex,
                    title: displayTitle(for: track),
                    languageCode: track.language,
                    isDefault: track.isDefault,
                    isForced: track.isForced,
                    cues: normalizeCueEnds(cues)
                )
            }
            let progressHandler: (([MatroskaSubtitleCue]) async -> Void)?
            if let onTrackExtracted {
                progressHandler = { partialCues in
                    await onTrackExtracted(makeExtractedTrack(partialCues))
                }
            } else {
                progressHandler = nil
            }
            var cues = try await extractIndexedCues(
                track: track,
                references: trackReferences,
                segmentContentOffset: resolvedMetadata.segmentContentOffset,
                timecodeScale: scale,
                source: source,
                priorityTime: priorityTime,
                onProgress: progressHandler
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

            let extracted = makeExtractedTrack(cues)
            output.append(extracted)
            if let onTrackExtracted { await onTrackExtracted(extracted) }
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
    static let contentEncodings: UInt64 = 0x6D80
    static let contentEncoding: UInt64 = 0x6240
    static let contentEncodingOrder: UInt64 = 0x5031
    static let contentEncodingScope: UInt64 = 0x5032
    static let contentEncodingType: UInt64 = 0x5033
    static let contentCompression: UInt64 = 0x5034
    static let contentCompAlgo: UInt64 = 0x4254
    static let contentCompSettings: UInt64 = 0x4255
    static let cues: UInt64 = 0x1C53BB6B
    static let cuePoint: UInt64 = 0xBB
    static let cueTime: UInt64 = 0xB3
    static let cueTrackPositions: UInt64 = 0xB7
    static let cueTrack: UInt64 = 0xF7
    static let cueClusterPosition: UInt64 = 0xF1
    static let cueRelativePosition: UInt64 = 0xF0
    static let cueDuration: UInt64 = 0xB2
    static let cueBlockNumber: UInt64 = 0x5378
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
    var contentEncodings: [MatroskaContentEncoding] = []

    var isSupportedTextSubtitle: Bool {
        guard type == 17 else { return false }
        return [
            "S_TEXT/UTF8",
            "S_TEXT/ASCII",
            "S_TEXT/ASS",
            "S_TEXT/SSA",
            "S_TEXT/USF",
            "S_TEXT/WEBVTT",
            "S_ASS",
            "S_SSA"
        ].contains(codecID.uppercased())
    }
}

private struct MatroskaContentEncoding: Sendable {
    let order: UInt64
    let scope: UInt64
    let type: UInt64
    let compression: MatroskaContentCompression?
}

private enum MatroskaContentCompression: Sendable {
    case zlib
    case headerStripping(Data)
    case unsupported(UInt64)
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
    let blockNumber: UInt64
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
            case MatroskaID.contentEncodings: track.contentEncodings = parseContentEncodings(data, element: child)
            default: break
            }
        }
        return track.number > 0 ? track : nil
    }
}

private func parseContentEncodings(_ data: Data, element: MatroskaElement) -> [MatroskaContentEncoding] {
    childElements(data, parent: element).compactMap { encoding in
        guard encoding.id == MatroskaID.contentEncoding else { return nil }
        var order: UInt64 = 0
        var scope: UInt64 = 1
        var type: UInt64 = 0
        var compression: MatroskaContentCompression?

        for child in childElements(data, parent: encoding) {
            switch child.id {
            case MatroskaID.contentEncodingOrder:
                order = unsignedInteger(data, element: child) ?? 0
            case MatroskaID.contentEncodingScope:
                scope = unsignedInteger(data, element: child) ?? 1
            case MatroskaID.contentEncodingType:
                type = unsignedInteger(data, element: child) ?? 0
            case MatroskaID.contentCompression:
                var algorithm: UInt64 = 0
                var settings = Data()
                for compressionChild in childElements(data, parent: child) {
                    if compressionChild.id == MatroskaID.contentCompAlgo {
                        algorithm = unsignedInteger(data, element: compressionChild) ?? 0
                    } else if compressionChild.id == MatroskaID.contentCompSettings {
                        settings = payload(data, element: compressionChild)
                    }
                }
                switch algorithm {
                case 0: compression = .zlib
                case 3: compression = .headerStripping(settings)
                default: compression = .unsupported(algorithm)
                }
            default:
                break
            }
        }
        return MatroskaContentEncoding(order: order, scope: scope, type: type, compression: compression)
    }
    .sorted { $0.order > $1.order }
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
            var blockNumber: UInt64 = 1
            for child in childElements(data, parent: positions) {
                switch child.id {
                case MatroskaID.cueTrack: track = unsignedInteger(data, element: child)
                case MatroskaID.cueClusterPosition: cluster = unsignedInteger(data, element: child)
                case MatroskaID.cueRelativePosition: relative = unsignedInteger(data, element: child)
                case MatroskaID.cueDuration: duration = unsignedInteger(data, element: child)
                case MatroskaID.cueBlockNumber: blockNumber = max(1, unsignedInteger(data, element: child) ?? 1)
                default: break
                }
            }
            if let track, let cluster {
                result.append(MatroskaCueReference(
                    trackNumber: track,
                    start: start,
                    duration: duration.map { seconds(ticks: $0, scale: timecodeScale) },
                    clusterPosition: cluster,
                    relativePosition: relative,
                    blockNumber: blockNumber
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
    source: MatroskaByteSource,
    priorityTime: Double?,
    onProgress: (([MatroskaSubtitleCue]) async -> Void)?
) async throws -> [MatroskaSubtitleCue] {
    guard !references.isEmpty else { return [] }
    let chronological = references.sorted { $0.start < $1.start }
    let ordered: [MatroskaCueReference]
    if let priorityTime, priorityTime > 0,
       let currentIndex = chronological.lastIndex(where: { $0.start <= priorityTime }) {
        // Start a little before the resume point so an already-visible cue is
        // included, then continue forward before filling the older history.
        let startIndex = max(0, currentIndex - 2)
        ordered = Array(chronological[startIndex...]) + Array(chronological[..<startIndex])
    } else {
        ordered = chronological
    }
    var indexed: [(Int, MatroskaSubtitleCue)] = []
    var lastPublishedCueCount = 0
    let directlyAddressable = ordered.enumerated().filter { $0.element.relativePosition != nil }

    // Bound concurrency so a long movie does not flood a remote WebDAV/CDN.
    for batchStart in stride(from: 0, to: directlyAddressable.count, by: 4) {
        try Task.checkCancellation()
        let batchEnd = min(directlyAddressable.count, batchStart + 4)
        let batch = Array(directlyAddressable[batchStart..<batchEnd])
        let values = try await withThrowingTaskGroup(of: (Int, MatroskaSubtitleCue?).self) { group in
            for (absoluteIndex, reference) in batch {
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
        let shouldPublish = indexed.count <= 4
            || indexed.count - lastPublishedCueCount >= 64
            || batchEnd == directlyAddressable.count
        if let onProgress, !indexed.isEmpty, shouldPublish {
            await onProgress(indexed.map(\.1).sorted { $0.start < $1.start })
            lastPublishedCueCount = indexed.count
        }
    }

    // CueRelativePosition is optional and many perfectly valid MKVs omit it.
    // Per Matroska, omission means the referenced frame is the first Block in
    // that Cluster. Read only headers plus that small subtitle Block; never
    // download an entire video Cluster just to locate one line of text.
    var seenClusterBlocks = Set<String>()
    let clusterOnlyReferences = ordered.filter { reference in
        guard reference.relativePosition == nil else { return false }
        return seenClusterBlocks.insert("\(reference.clusterPosition):\(reference.blockNumber)").inserted
    }
    var clusterCues: [MatroskaSubtitleCue] = []
    for reference in clusterOnlyReferences {
        try Task.checkCancellation()
        do {
            if let cue = try await decodeSubtitleCueAtBlockNumber(
                track: track,
                reference: reference,
                segmentContentOffset: segmentContentOffset,
                timecodeScale: timecodeScale,
                source: source
            ) {
                clusterCues.append(cue)
                let totalCueCount = indexed.count + clusterCues.count
                if let onProgress,
                   (totalCueCount - lastPublishedCueCount >= 64 || totalCueCount == 1) {
                    await onProgress((indexed.map(\.1) + clusterCues).sorted { $0.start < $1.start })
                    lastPublishedCueCount = totalCueCount
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A corrupt/oversized Cluster should not hide valid cues from the
            // remaining Clusters or the directly addressed entries above.
            continue
        }
    }

    return (indexed.map(\.1) + clusterCues).sorted { $0.start < $1.start }
}

private func decodeSubtitleCueAtBlockNumber(
    track: MatroskaTrack,
    reference: MatroskaCueReference,
    segmentContentOffset: UInt64,
    timecodeScale: UInt64,
    source: MatroskaByteSource
) async throws -> MatroskaSubtitleCue? {
    let clusterOffset = segmentContentOffset + reference.clusterPosition
    guard let cluster = try await readHeader(at: clusterOffset, from: source),
          cluster.id == MatroskaID.cluster,
          let clusterTotal = cluster.totalSize else { return nil }
    let clusterEnd = clusterOffset + clusterTotal
    var cursor = clusterOffset + UInt64(cluster.headerSize)
    var clusterTimecode: UInt64 = 0
    var encounteredBlocks: UInt64 = 0

    while cursor + 2 < clusterEnd {
        try Task.checkCancellation()
        guard let child = try await readHeader(at: cursor, from: source),
              let childTotal = child.totalSize,
              childTotal > 0,
              cursor + childTotal <= clusterEnd else { return nil }

        if child.id == MatroskaID.clusterTimecode {
            let valueData = try await source.read(offset: cursor, count: Int(childTotal))
            if let local = parseElementHeader(valueData, at: 0) {
                clusterTimecode = unsignedInteger(valueData, element: local) ?? 0
            }
        } else if child.id == MatroskaID.simpleBlock || child.id == MatroskaID.blockGroup {
            encounteredBlocks += 1
            guard encounteredBlocks == reference.blockNumber else {
                cursor += childTotal
                continue
            }
            // Read only the specifically indexed Block. All video/audio Block
            // payloads before it were skipped using their EBML sizes.
            let elementData = try await readElement(
                at: cursor,
                from: source,
                maximumSize: 1 * 1_024 * 1_024
            )
            guard blockTrackNumber(in: elementData) == track.number else { return nil }
            return decodeScannedElement(
                elementData,
                track: track,
                clusterTimecode: clusterTimecode,
                scale: timecodeScale
            )
        }
        cursor += childTotal
    }
    return nil
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
    let text = block.frames.compactMap { decodeSubtitleText($0, track: track) }.joined(separator: "\n")
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
    let text = block.frames.compactMap { decodeSubtitleText($0, track: track) }.joined(separator: "\n")
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
    guard let frames = decodeLacedFrames(data, offset: frameOffset, lacing: lacing) else { return nil }
    return DecodedBlock(
        trackNumber: trackVINT.value,
        relativeTimecode: relativeTime,
        frames: frames
    )
}

private func decodeLacedFrames(_ data: Data, offset: Int, lacing: UInt8) -> [Data]? {
    guard offset <= data.count else { return nil }
    if lacing == 0 { return [Data(data[offset..<data.count])] }
    guard offset < data.count else { return nil }

    let frameCount = Int(data[offset]) + 1
    guard frameCount > 0 else { return nil }
    var cursor = offset + 1
    var sizes: [Int] = []

    switch lacing {
    case 1: // Xiph lacing
        for _ in 0..<(frameCount - 1) {
            var size = 0
            while true {
                guard cursor < data.count else { return nil }
                let byte = Int(data[cursor])
                cursor += 1
                guard size <= Int.max - byte else { return nil }
                size += byte
                if byte != 255 { break }
            }
            sizes.append(size)
        }

    case 2: // Fixed-size lacing
        let remaining = data.count - cursor
        guard remaining % frameCount == 0 else { return nil }
        sizes = Array(repeating: remaining / frameCount, count: frameCount - 1)

    case 3: // EBML lacing
        guard let firstSize = parseVINT(data, at: cursor, removingMarker: true),
              firstSize.value <= UInt64(Int.max) else { return nil }
        cursor += firstSize.length
        sizes.append(Int(firstSize.value))

        if frameCount > 2 {
            for _ in 1..<(frameCount - 1) {
                guard let encodedDelta = parseVINT(data, at: cursor, removingMarker: true) else { return nil }
                cursor += encodedDelta.length
                let bitCount = 7 * encodedDelta.length
                let bias = (Int64(1) << (bitCount - 1)) - 1
                guard encodedDelta.value <= UInt64(Int64.max) else { return nil }
                let delta = Int64(encodedDelta.value) - bias
                let previous = Int64(sizes[sizes.count - 1])
                let next = previous + delta
                guard next >= 0, next <= Int64(Int.max) else { return nil }
                sizes.append(Int(next))
            }
        }

    default:
        return nil
    }

    let remaining = data.count - cursor
    let knownTotal = sizes.reduce(0) { partial, size in
        partial > Int.max - size ? Int.max : partial + size
    }
    guard knownTotal <= remaining else { return nil }
    sizes.append(remaining - knownTotal)
    guard sizes.count == frameCount else { return nil }

    var frames: [Data] = []
    frames.reserveCapacity(frameCount)
    for size in sizes {
        guard size >= 0, cursor <= data.count - size else { return nil }
        frames.append(Data(data[cursor..<(cursor + size)]))
        cursor += size
    }
    return cursor == data.count ? frames : nil
}

private func decodeSubtitleText(_ data: Data, track: MatroskaTrack) -> String? {
    guard let decodedData = decodeContentEncodings(data, encodings: track.contentEncodings),
          var text = String(data: decodedData, encoding: .utf8) else { return nil }
    let codec = track.codecID.uppercased()
    if codec == "S_TEXT/ASS" || codec == "S_TEXT/SSA" || codec == "S_ASS" || codec == "S_SSA" {
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
        .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&apos;", with: "'")
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "\u{FEFF}", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}

/// Content encodings are applied in ascending order while muxing, therefore
/// they must be undone from the highest order to the lowest. Scope bit 0
/// identifies Block frame data; private/next encoding scopes do not apply here.
private func decodeContentEncodings(_ data: Data, encodings: [MatroskaContentEncoding]) -> Data? {
    var result = data
    for encoding in encodings where encoding.scope & 0x01 != 0 {
        // Encryption (type 1) and unknown future encoding types cannot be
        // decoded locally. Returning nil keeps VLC as the safe fallback.
        guard encoding.type == 0 else { return nil }
        guard let compression = encoding.compression else { continue }
        switch compression {
        case .zlib:
            guard let inflated = decompressZlib(result) else { return nil }
            result = inflated
        case .headerStripping(let prefix):
            var restored = prefix
            restored.append(result)
            result = restored
        case .unsupported:
            return nil
        }
    }
    return result
}

private func decompressZlib(_ data: Data) -> Data? {
    guard !data.isEmpty else { return Data() }
    var capacity = max(4_096, data.count * 8)
    let maximumCapacity = 4 * 1_024 * 1_024

    while capacity <= maximumCapacity {
        var output = Data(count: capacity)
        let decodedCount: Int = output.withUnsafeMutableBytes { destinationBytes in
            data.withUnsafeBytes { sourceBytes in
                guard let destination = destinationBytes.bindMemory(to: UInt8.self).baseAddress,
                      let source = sourceBytes.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destination,
                    capacity,
                    source,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        if decodedCount > 0 {
            output.count = decodedCount
            return output
        }
        capacity *= 2
    }
    return nil
}

private func normalizeCueEnds(_ cues: [MatroskaSubtitleCue]) -> [MatroskaSubtitleCue] {
    let sorted = cues.sorted { lhs, rhs in lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start }
    var seen = Set<String>()
    let ordered = sorted.filter { cue in
        let key = "\(Int((cue.start * 1_000).rounded()))|\(cue.text)"
        return seen.insert(key).inserted
    }
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
