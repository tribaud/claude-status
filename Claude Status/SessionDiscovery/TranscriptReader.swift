import Foundation

/// One displayable item of a Claude Code transcript (`<session-id>.jsonl`).
struct TranscriptEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(String)
        case assistant(String)
        /// Claude's reasoning. Transcripts only keep a signature, not the text.
        case thinking
        case toolUse(name: String, summary: String)
        case toolResult(String, isError: Bool)
    }

    /// Position in the parsed slice; stable while the slice doesn't move.
    let id: Int
    let kind: Kind
}

/// Reads Claude Code transcripts: the tail for a live preview, and the
/// conversation title (`custom-title` from /rename, else `ai-title`).
enum TranscriptReader {

    /// Transcript path for a `.cstatus` file: same directory and session ID.
    static func transcriptURL(forCStatus url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("jsonl")
    }

    /// Parses the last `maxBytes` of the transcript and returns its last `limit` entries.
    static func tail(of url: URL, maxBytes: Int = 512 * 1024, limit: Int = 60) -> [TranscriptEntry] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }

        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // A slice that doesn't start at the file's beginning cuts its first line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }

        let kinds = lines.flatMap { parse(line: Data($0)) }
        let kept = kinds.suffix(limit)
        return kept.enumerated().map { TranscriptEntry(id: $0.offset, kind: $0.element) }
    }

    /// Displayable items of one transcript line. Metadata lines yield nothing.
    static func parse(line: Data) -> [TranscriptEntry.Kind] {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = json["type"] as? String, type == "user" || type == "assistant",
              json["isMeta"] as? Bool != true,
              let message = json["message"] as? [String: Any] else {
            return []
        }

        if let text = message["content"] as? String {
            return userText(text).map { [.user($0)] } ?? []
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }

        return blocks.compactMap { block -> TranscriptEntry.Kind? in
            switch block["type"] as? String {
            case "text":
                guard let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                if type == "assistant" { return .assistant(text) }
                return userText(text).map { .user($0) }
            case "thinking":
                return .thinking
            case "tool_use":
                let name = block["name"] as? String ?? "Tool"
                let input = block["input"] as? [String: Any] ?? [:]
                return .toolUse(name: name, summary: toolSummary(name: name, input: input))
            case "tool_result":
                return .toolResult(resultText(block["content"]), isError: block["is_error"] as? Bool == true)
            default:
                return nil
            }
        }
    }

    /// User text worth showing: drops the wrappers Claude Code injects
    /// (slash commands, local command output, system reminders).
    private static func userText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for prefix in ["<command-", "<local-command-", "<system-reminder>", "<bash-", "Caveat: "] where trimmed.hasPrefix(prefix) {
            return nil
        }
        return trimmed
    }

    /// One-line description of a tool call, e.g. the command or file it touches.
    static func toolSummary(name: String, input: [String: Any]) -> String {
        if name == "AskUserQuestion", let questions = input["questions"] as? [[String: Any]] {
            return questions.compactMap { $0["question"] as? String }.joined(separator: "\n")
        }
        for key in ["description", "command", "file_path", "pattern", "url", "query", "prompt", "skill"] {
            if let value = input[key] as? String, !value.isEmpty {
                return value
            }
        }
        return ""
    }

    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    // MARK: - Title

    private static let titleMarker = Data(#"-title""#.utf8)

    /// Title found in one line, if the line is a title record.
    static func title(inLine line: Data) -> (custom: String?, ai: String?)? {
        // Cheap filter before decoding: title records are short and rare.
        guard line.count < 4096, line.containsBytes(titleMarker),
              let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return nil
        }
        switch json["type"] as? String {
        case "custom-title": return (json["customTitle"] as? String, nil)
        case "ai-title": return (nil, json["aiTitle"] as? String)
        default: return nil
        }
    }
}

/// What a transcript says about the prompt cache: when the last API request
/// refreshed it, and for how long it lives.
struct PromptCacheState: Equatable {
    var refreshedAt: Date
    var ttl: TimeInterval

    var expiresAt: Date { refreshedAt.addingTimeInterval(ttl) }

    static let defaultTTL: TimeInterval = 3600
}

extension TranscriptReader {

    private static let cacheMarker = Data(#""cache_creation""#.utf8)
    private static let userMarker = Data(#""type":"user""#.utf8)
    private static let sidechainMarker = Data(#""isSidechain":true"#.utf8)

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Kind of line that matters for the prompt cache, read without decoding the
    /// (possibly huge) JSON: the top-level `timestamp` key is the only unescaped
    /// `"timestamp":"` in a line, since nested JSON text is escaped (checked on
    /// real transcripts: no nested object carries that key).
    ///
    /// Timestamps stay raw (`2026-10-14T13:44:33.526Z`): Claude Code writes them in
    /// one fixed UTC format, so they compare as strings, and only the one kept is
    /// parsed. Parsing every line made the first read of a large transcript slow.
    enum CacheLine: Equatable {
        /// A user message or tool result: the next API request is sent right after.
        case request(at: String)
        /// An API response with its cache writes, in tokens per TTL.
        case response(at: String, oneHourTokens: Int, fiveMinuteTokens: Int)
    }

    static func cacheLine(_ line: Data) -> CacheLine? {
        // `isSidechain` and a user line's `type` are among the first keys: checking
        // the head keeps large tool results from being scanned end to end.
        let head = line.prefix(512)
        // Subagents keep their own caches.
        guard !head.containsBytes(sidechainMarker) else { return nil }
        if head.containsBytes(userMarker) {
            return rawTimestamp(in: line).map { .request(at: $0) }
        }
        guard line.containsBytes(cacheMarker), let date = rawTimestamp(in: line) else { return nil }
        do {
            return .response(
                at: date,
                oneHourTokens: integer(after: #""ephemeral_1h_input_tokens":"#, in: line) ?? 0,
                fiveMinuteTokens: integer(after: #""ephemeral_5m_input_tokens":"#, in: line) ?? 0
            )
        }
    }

    private static let timestampKey = Data(#""timestamp":""#.utf8)

    private static func rawTimestamp(in line: Data) -> String? {
        guard let start = line.endOfBytes(timestampKey) else { return nil }
        let rest = line[start...].prefix(40)
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: rest[rest.startIndex..<end], as: UTF8.self)
    }

    static func date(fromTimestamp raw: String) -> Date? {
        timestampFormatter.date(from: raw)
    }

    private static func integer(after key: String, in line: Data) -> Int? {
        guard let end = line.endOfBytes(Data(key.utf8)) else { return nil }
        let digits = line[end...].prefix { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
        return Int(String(decoding: digits, as: UTF8.self))
    }
}

/// Follows conversation titles and the prompt cache incrementally: each call
/// reads only the bytes appended since the previous one.
final class TranscriptMetadataCache {

    struct Metadata: Equatable {
        var title: String?
        var promptCache: PromptCacheState?
    }

    private struct State {
        var offset: UInt64 = 0
        var customTitle: String?
        var aiTitle: String?
        var lastRequestAt: String?
        var cacheRefreshedAt: String?
        var cacheTTL: TimeInterval?
        /// Parsed `cacheRefreshedAt`, kept while it doesn't change.
        var promptCache: PromptCacheState?
        var promptCacheRaw: String?
    }

    private var states: [String: State] = [:]  // keyed by path

    /// Title (latest custom title, else latest AI title) and prompt cache state
    /// of the transcript at `url`.
    func metadata(for url: URL) -> Metadata {
        var state = states[url.path] ?? State()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Metadata() }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < state.offset { state = State() }  // rewritten or truncated
        if size > state.offset {
            try? handle.seek(toOffset: state.offset)
            if let data = try? handle.readToEnd() {
                // Only complete lines; a partial last line is read on the next call.
                state.offset += UInt64(data.forEachLine { Self.apply($0, to: &state) })
            }
        }
        if let raw = state.cacheRefreshedAt, let ttl = state.cacheTTL,
           state.promptCache?.ttl != ttl || state.promptCacheRaw != raw {
            state.promptCache = TranscriptReader.date(fromTimestamp: raw).map { PromptCacheState(refreshedAt: $0, ttl: ttl) }
            state.promptCacheRaw = raw
        }
        states[url.path] = state
        return Metadata(title: state.customTitle ?? state.aiTitle, promptCache: state.promptCache)
    }

    private static func apply(_ line: Data, to state: inout State) {
        if let found = TranscriptReader.title(inLine: line) {
            if let custom = found.custom { state.customTitle = custom }
            if let ai = found.ai { state.aiTitle = ai }
            return
        }
        switch TranscriptReader.cacheLine(line) {
        case .request(let date):
            state.lastRequestAt = date
        case .response(let date, let oneHour, let fiveMinutes):
            // A response without cache writes only read the cache, which keeps its TTL.
            state.cacheTTL = oneHour > 0 ? 3600
                : fiveMinutes > 0 ? 300
                : state.cacheTTL ?? PromptCacheState.defaultTTL
            // The request left right after the last user line, before this response.
            state.cacheRefreshedAt = state.lastRequestAt.map { min($0, date) } ?? date
        case nil:
            break
        }
    }

    /// Drops transcripts no longer in use.
    func retain(onlyPaths paths: Set<String>) {
        states = states.filter { paths.contains($0.key) }
    }
}

extension Data {
    /// Calls `body` with each complete line (newline excluded), as slices of this
    /// data, and returns the number of bytes consumed, up to the last newline.
    func forEachLine(_ body: (Data) -> Void) -> Int {
        var consumed = 0
        withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var start = 0
            while start < buffer.count,
                  let found = memchr(base + start, Int32(UInt8(ascii: "\n")), buffer.count - start) {
                let end = base.distance(to: UnsafeRawPointer(found))
                if end > start { body(self[(startIndex + start)..<(startIndex + end)]) }
                start = end + 1
                consumed = start
            }
        }
        return consumed
    }

    /// Byte search through `memmem`: `range(of:)` is several times slower, which
    /// shows on the first read of transcripts weighing tens of megabytes.
    func containsBytes(_ needle: Data) -> Bool {
        endOfBytes(needle) != nil
    }

    /// Index just past the first occurrence of `needle`, if any.
    func endOfBytes(_ needle: Data) -> Index? {
        let offset: Int? = withUnsafeBytes { haystack in
            needle.withUnsafeBytes { pattern in
                guard let base = haystack.baseAddress,
                      let found = memmem(base, haystack.count, pattern.baseAddress, pattern.count) else { return nil }
                return base.distance(to: UnsafeRawPointer(found)) + pattern.count
            }
        }
        return offset.map { startIndex + $0 }
    }
}
