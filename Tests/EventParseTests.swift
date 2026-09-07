import XCTest
@testable import Notchification

final class EventParseTests: XCTestCase {
    func testClaudeHookWrappedWithTerminal() {
        let ev = EventWatcher.parse([
            "term_program": "kitty", "kitty_win": "3",
            "payload": ["hook_event_name": "Notification", "session_id": "s1",
                        "cwd": "/x/notchification", "message": "Allow Bash?"],
        ])!
        XCTAssertEqual(ev.kind, .notification)
        XCTAssertEqual(ev.agent, .claude)
        XCTAssertEqual(ev.project, "notchification")
        XCTAssertEqual(ev.sessionId, "s1")
        XCTAssertEqual(ev.message, "Allow Bash?")
        XCTAssertEqual(ev.term?.kittyWin, "3")
    }

    func testCodexNotifyPayload() {
        let ev = EventWatcher.parse([
            "agent": "codex", "cwd": "/x/miko-manager",
            "payload": ["type": "agent-turn-complete", "thread-id": "t1",
                        "last-assistant-message": "Published 1.4.2"],
        ])!
        XCTAssertEqual(ev.kind, .stop)
        XCTAssertEqual(ev.agent, .codex)
        XCTAssertEqual(ev.project, "miko-manager")
        XCTAssertEqual(ev.sessionId, "t1")
        XCTAssertEqual(ev.message, "Published 1.4.2")
    }

    func testBareCodexPayloadDefaultsToCodexAndUnknownIsDropped() {
        XCTAssertEqual(EventWatcher.parse(["type": "agent-turn-complete", "thread-id": "t2"])?.agent, .codex)
        XCTAssertEqual(EventWatcher.parse(["type": "agent-turn-complete", "thread-id": "t2"])?.project, "Codex Code")
        XCTAssertNil(EventWatcher.parse(["hook_event_name": "PreToolUse"]))
    }
}
