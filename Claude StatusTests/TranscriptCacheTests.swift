import Foundation
import Testing
@testable import Claude_Status

struct PromptCacheTests {

    private func line(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)!
    }

    private func user(_ at: String, sidechain: Bool = false) -> [String: Any] {
        ["type": "user", "isSidechain": sidechain, "timestamp": at,
         "message": ["role": "user", "content": "text with \"timestamp\":\"2000-01-01T00:00:00.000Z\" inside"]]
    }

    private func assistant(_ at: String, oneHour: Int, fiveMinutes: Int) -> [String: Any] {
        ["type": "assistant", "isSidechain": false, "timestamp": at, "message": [
            "role": "assistant", "content": [["type": "text", "text": "ok"]],
            "usage": ["cache_creation": ["ephemeral_1h_input_tokens": oneHour, "ephemeral_5m_input_tokens": fiveMinutes]],
        ]]
    }

    @Test func readsCacheLinesWithoutDecoding() {
        #expect(TranscriptReader.cacheLine(line(user("2026-10-14T13:44:33.526Z"))) == .request(at: "2026-10-14T13:44:33.526Z"))
        #expect(TranscriptReader.cacheLine(line(assistant("2026-10-14T13:44:39.150Z", oneHour: 563, fiveMinutes: 0)))
            == .response(at: "2026-10-14T13:44:39.150Z", oneHourTokens: 563, fiveMinuteTokens: 0))
        #expect(TranscriptReader.cacheLine(line(user("2026-10-14T13:44:33.526Z", sidechain: true))) == nil)
        #expect(TranscriptReader.cacheLine(line(["type": "ai-title", "aiTitle": "x"])) == nil)
    }

    private func write(_ objects: [[String: Any]]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        var data = Data()
        for object in objects {
            data.append(line(object))
            data.append(UInt8(ascii: "\n"))
        }
        try data.write(to: url)
        return url
    }

    @Test func expiryStartsAtTheRequest() throws {
        let url = try write([
            user("2026-10-14T13:00:00.000Z"),
            assistant("2026-10-14T13:02:30.000Z", oneHour: 100, fiveMinutes: 0),
            assistant("2026-10-14T13:02:31.000Z", oneHour: 100, fiveMinutes: 0),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = try #require(TranscriptMetadataCache().metadata(for: url).promptCache)
        #expect(cache.refreshedAt == date("2026-10-14T13:00:00.000Z"))
        #expect(cache.expiresAt == date("2026-10-14T14:00:00.000Z"))
    }

    @Test func fiveMinuteTTLAndCacheReadsKeepIt() throws {
        let url = try write([
            user("2026-10-14T13:00:00.000Z"),
            assistant("2026-10-14T13:00:05.000Z", oneHour: 0, fiveMinutes: 40),
            user("2026-10-14T13:03:00.000Z"),
            assistant("2026-10-14T13:03:05.000Z", oneHour: 0, fiveMinutes: 0),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = try #require(TranscriptMetadataCache().metadata(for: url).promptCache)
        #expect(cache.ttl == 300)
        #expect(cache.expiresAt == date("2026-10-14T13:08:00.000Z"))
    }

    @Test func readsAppendedLinesAndKeepsPartialOnes() throws {
        let url = try write([user("2026-10-14T13:00:00.000Z")])
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = TranscriptMetadataCache()
        #expect(cache.metadata(for: url).promptCache == nil)

        // A response written in two steps: nothing counts until its newline lands.
        var response = line(assistant("2026-10-14T13:00:10.000Z", oneHour: 0, fiveMinutes: 9))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: response.prefix(20))
        #expect(cache.metadata(for: url).promptCache == nil)
        response.append(UInt8(ascii: "\n"))
        try handle.write(contentsOf: response.dropFirst(20))
        try handle.close()
        #expect(cache.metadata(for: url).promptCache?.expiresAt == date("2026-10-14T13:05:00.000Z"))
    }

    @Test func formatsCountdown() {
        #expect(PromptCacheCountdown.format(3600) == "1:00:00")
        #expect(PromptCacheCountdown.format(2533.2) == "42:14")
        #expect(PromptCacheCountdown.format(5) == "0:05")
    }

    @Test func sortsWaitingSessionsByExpiry() {
        let now = date("2026-10-14T13:00:00.000Z")
        func session(_ id: String, expires minutes: Double?, activity: Double) -> ClaudeSession {
            var s = ClaudeSession(
                sessionId: id, pid: 1, workingDirectory: "/tmp", projectName: id, state: .waiting,
                lastActivityAt: now.addingTimeInterval(activity), iTermSessionId: nil, tmuxPaneId: nil,
                tmuxSocket: nil, source: .vscode, activity: "", sessionName: nil
            )
            s.promptCacheExpiresAt = minutes.map { now.addingTimeInterval($0 * 60) }
            return s
        }
        let sessions = [
            session("late", expires: 50, activity: -10),
            session("expired", expires: -5, activity: 0),
            session("soon", expires: 3, activity: -600),
            session("unknown", expires: nil, activity: -1),
        ]
        #expect(sessions.sortedByStateAndActivity(now: now).map(\.sessionId) == ["soon", "late", "expired", "unknown"])
    }
}
