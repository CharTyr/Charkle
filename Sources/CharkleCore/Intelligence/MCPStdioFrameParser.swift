import Foundation

/// Incremental, chunk-boundary-safe stdio frame parser for MCP JSON-RPC 2.0 streams.
///
/// Supports both:
/// - Standard MCP newline-delimited JSON (`NDJSON`)
/// - LSP-style `Content-Length: <bytes>\r\n\r\n<body>` (and `\n\n` fallback)
///
/// Crucially, partial `Content-Length` headers split across arbitrary `read()` chunks are preserved
/// intact rather than misclassified as NDJSON lines.
public nonisolated struct MCPStdioFrameParser: Sendable {
    public enum Framing: Equatable, Sendable {
        case ndjson
        case contentLength
    }

    public enum Event: Equatable, Sendable {
        case message(Data, framing: Framing)
        case invalidFrame(String, framing: Framing)
    }

    public let maxFrameBytes: Int
    private var buffer = Data()
    private var discardingNDJSONLine = false
    private var discardingContentLengthRemaining = 0
    private var headerOnlyDiscardCandidate: Data?

    private static let crlfSeparator = Data("\r\n\r\n".utf8)
    private static let lfSeparator = Data("\n\n".utf8)
    private static let maxHeaderBytes = 8 * 1024

    public init(maxFrameBytes: Int = 32 * 1024 * 1024) {
        self.maxFrameBytes = max(1024, maxFrameBytes)
    }

    public mutating func append(_ chunk: Data) -> [Event] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)
        return drainAvailable()
    }

    public mutating func finishEOF() -> [Event] {
        var events = drainAvailable()
        if discardingContentLengthRemaining > 0 {
            let candidate = headerOnlyDiscardCandidate
            buffer.removeAll(keepingCapacity: false)
            discardingContentLengthRemaining = 0
            headerOnlyDiscardCandidate = nil
            // If an oversized Content-Length header arrived with zero body bytes and was followed
            // only by a complete standalone JSON payload before EOF, recover it cleanly as NDJSON.
            if let candidate {
                let trimmed = Self.trimWhitespace(candidate)
                if !trimmed.isEmpty,
                   trimmed.count <= maxFrameBytes,
                   (trimmed[trimmed.startIndex] == 0x7B || trimmed[trimmed.startIndex] == 0x5B),
                   (try? JSONSerialization.jsonObject(with: trimmed)) != nil {
                    events.append(.message(trimmed, framing: .ndjson))
                }
            }
            return events
        }
        if discardingNDJSONLine {
            buffer.removeAll(keepingCapacity: false)
            discardingNDJSONLine = false
            return events
        }
        let remaining = Self.trimWhitespace(buffer)
        buffer.removeAll(keepingCapacity: false)
        if !remaining.isEmpty {
            let first = remaining[remaining.startIndex]
            if first == 0x7B || first == 0x5B { // '{' or '['
                if remaining.count > maxFrameBytes {
                    events.append(.invalidFrame("NDJSON frame exceeds limit \(maxFrameBytes)", framing: .ndjson))
                } else {
                    events.append(.message(remaining, framing: .ndjson))
                }
            } else {
                events.append(.invalidFrame("Incomplete trailing stdio frame at EOF", framing: .ndjson))
            }
        }
        return events
    }

    public static func encode(_ payload: Data, framing: Framing) -> Data {
        switch framing {
        case .ndjson:
            var out = Data(capacity: payload.count + 1)
            out.append(payload)
            out.append(0x0A)
            return out
        case .contentLength:
            let header = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
            var out = Data(capacity: header.count + payload.count)
            out.append(header)
            out.append(payload)
            return out
        }
    }

    // MARK: - Internal State Machine

    private mutating func drainAvailable() -> [Event] {
        var events: [Event] = []

        while true {
            if discardingContentLengthRemaining > 0 {
                let toDrop = min(buffer.count, discardingContentLengthRemaining)
                if toDrop > 0 {
                    if var candidate = headerOnlyDiscardCandidate {
                        if candidate.count + toDrop <= maxFrameBytes {
                            candidate.append(buffer[buffer.startIndex..<(buffer.startIndex + toDrop)])
                            headerOnlyDiscardCandidate = candidate
                        } else {
                            headerOnlyDiscardCandidate = nil
                        }
                    }
                    buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + toDrop))
                    discardingContentLengthRemaining -= toDrop
                }
                if discardingContentLengthRemaining > 0 {
                    break
                }
                headerOnlyDiscardCandidate = nil
            }

            if discardingNDJSONLine {
                if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    buffer.removeSubrange(buffer.startIndex...newlineIndex)
                    discardingNDJSONLine = false
                } else {
                    buffer.removeAll(keepingCapacity: true)
                    break
                }
            }

            trimLeadingBlankBytes()
            guard let firstByte = buffer.first else { break }

            // JSON object ('{') or JSON-RPC batch array ('[') -> NDJSON line mode.
            if firstByte == 0x7B || firstByte == 0x5B {
                guard let newlineIndex = buffer.firstIndex(of: 0x0A) else {
                    if buffer.count > maxFrameBytes {
                        buffer.removeAll(keepingCapacity: true)
                        discardingNDJSONLine = true
                        events.append(.invalidFrame("NDJSON frame exceeds limit \(maxFrameBytes)", framing: .ndjson))
                    }
                    break
                }
                let rawLine = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                let trimmed = Self.trimWhitespace(rawLine)
                if trimmed.count > maxFrameBytes {
                    events.append(.invalidFrame("NDJSON frame exceeds limit \(maxFrameBytes)", framing: .ndjson))
                } else if !trimmed.isEmpty {
                    events.append(.message(trimmed, framing: .ndjson))
                }
                continue
            }

            // ASCII header start (e.g. `Content-Length:` / `Content-Type:`) -> wait for full header block.
            if Self.isHeaderLeadByte(firstByte) {
                guard let headerRange = findHeaderTerminator() else {
                    if let firstNewline = buffer.firstIndex(of: 0x0A) {
                        let firstLine = buffer[buffer.startIndex..<firstNewline]
                        // Valid LSP/MCP headers always contain `:` on their first line; bare ASCII
                        // tokens like `null\n` or `true\n` must not stall the stream waiting for `\r\n\r\n`.
                        if !firstLine.contains(0x3A) {
                            buffer.removeSubrange(buffer.startIndex...firstNewline)
                            events.append(.invalidFrame("Unrecognized stdio frame", framing: .ndjson))
                            continue
                        }
                    }
                    if buffer.count > Self.maxHeaderBytes {
                        // Malformed unbounded non-JSON line — drop up to next newline to recover.
                        if let nl = buffer.firstIndex(of: 0x0A) {
                            buffer.removeSubrange(buffer.startIndex...nl)
                        } else {
                            buffer.removeAll(keepingCapacity: true)
                        }
                        events.append(.invalidFrame("Malformed stdio header exceeds \(Self.maxHeaderBytes) bytes", framing: .contentLength))
                        continue
                    }
                    break // Wait for more header bytes to arrive.
                }

                let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
                guard let headerText = String(data: headerData, encoding: .utf8) else {
                    buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)
                    events.append(.invalidFrame("Non-UTF8 Content-Length header", framing: .contentLength))
                    continue
                }

                var parsedLength: Int?
                for line in headerText.split(whereSeparator: \.isNewline) {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                    if key == "content-length" {
                        parsedLength = Int(parts[1].trimmingCharacters(in: .whitespaces))
                    }
                }

                guard let contentLength = parsedLength, contentLength >= 0 else {
                    buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)
                    events.append(.invalidFrame("Missing or invalid Content-Length header", framing: .contentLength))
                    continue
                }

                guard contentLength <= maxFrameBytes else {
                    let bodyStart = headerRange.upperBound
                    let bufferedBodyBytes = buffer.endIndex - bodyStart
                    let dropBodyBytes = min(bufferedBodyBytes, contentLength)
                    buffer.removeSubrange(buffer.startIndex..<(bodyStart + dropBodyBytes))
                    discardingContentLengthRemaining = contentLength - dropBodyBytes
                    headerOnlyDiscardCandidate = (bufferedBodyBytes == 0 && discardingContentLengthRemaining > 0) ? Data() : nil
                    events.append(.invalidFrame("Content-Length \(contentLength) exceeds limit \(maxFrameBytes)", framing: .contentLength))
                    continue
                }

                let bodyStart = headerRange.upperBound
                let (bodyEnd, overflow) = bodyStart.addingReportingOverflow(contentLength)
                guard !overflow, buffer.endIndex >= bodyEnd else {
                    break // Wait for full framed body to arrive.
                }

                let payload = buffer.subdata(in: bodyStart..<bodyEnd)
                buffer.removeSubrange(buffer.startIndex..<bodyEnd)
                events.append(.message(payload, framing: .contentLength))
                continue
            }

            // Unexpected non-JSON, non-header line: consume through next newline and report parse error.
            guard let newlineIndex = buffer.firstIndex(of: 0x0A) else {
                if buffer.count > Self.maxHeaderBytes {
                    buffer.removeAll(keepingCapacity: true)
                    events.append(.invalidFrame("Unrecognized stdio frame", framing: .ndjson))
                }
                break
            }
            let garbage = Self.trimWhitespace(buffer.subdata(in: buffer.startIndex..<newlineIndex))
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            if !garbage.isEmpty {
                events.append(.message(garbage, framing: .ndjson))
            }
        }

        return events
    }

    private mutating func trimLeadingBlankBytes() {
        var idx = buffer.startIndex
        while idx < buffer.endIndex {
            let b = buffer[idx]
            if b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0A {
                idx += 1
            } else {
                break
            }
        }
        if idx > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<idx)
        }
    }

    private func findHeaderTerminator() -> Range<Data.Index>? {
        let crlf = buffer.range(of: Self.crlfSeparator)
        let lf = buffer.range(of: Self.lfSeparator)
        switch (crlf, lf) {
        case (let a?, let b?):
            return a.lowerBound <= b.lowerBound ? a : b
        case (let a?, nil):
            return a
        case (nil, let b?):
            return b
        case (nil, nil):
            return nil
        }
    }

    private static func isHeaderLeadByte(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    private static func trimWhitespace(_ data: Data) -> Data {
        var start = data.startIndex
        var end = data.endIndex
        while start < end && (data[start] == 0x20 || data[start] == 0x09 || data[start] == 0x0D || data[start] == 0x0A) {
            start += 1
        }
        while end > start && (data[end - 1] == 0x20 || data[end - 1] == 0x09 || data[end - 1] == 0x0D || data[end - 1] == 0x0A) {
            end -= 1
        }
        return data.subdata(in: start..<end)
    }
}
