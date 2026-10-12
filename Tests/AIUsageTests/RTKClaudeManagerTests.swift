import XCTest
@testable import AIUsage

final class RTKClaudeManagerTests: XCTestCase {
    func testFindsClaudeHookInNestedSettings() {
        let settings: [String: Any] = [
            "hooks": [
                "PreToolUse": [[
                    "hooks": [["type": "command", "command": "/opt/homebrew/bin/rtk hook claude"]]
                ]]
            ]
        ]

        XCTAssertTrue(RTKClaudeManager.containsRTKClaudeHook(settings))
    }

    func testDoesNotTreatUnrelatedRTKConfigurationAsClaudeHook() {
        let settings: [String: Any] = [
            "env": ["RTK_LOG_LEVEL": "debug"],
            "hooks": ["PostToolUse": [["command": "rtk gain"]]]
        ]

        XCTAssertFalse(RTKClaudeManager.containsRTKClaudeHook(settings))
    }

    func testFindsCodexAndGeminiHooks() {
        let codexSettings: [String: Any] = [
            "hooks": ["PreToolUse": [["command": "rtk hook codex"]]]
        ]
        let geminiSettings: [String: Any] = [
            "hooks": ["BeforeTool": [["hooks": [["command": "rtk hook gemini"]]]]]
        ]

        XCTAssertTrue(RTKAgentManager.containsHook(codexSettings, for: .codex))
        XCTAssertTrue(RTKAgentManager.containsHook(geminiSettings, for: .gemini))
        XCTAssertFalse(RTKAgentManager.containsHook(geminiSettings, for: .codex))
    }

    func testDetectsExistingGeminiBeforeToolHooks() {
        XCTAssertTrue(RTKAgentManager.hasGeminiBeforeToolHooks([
            "hooks": ["BeforeTool": [["matcher": "run_shell_command"]]]
        ]))
        XCTAssertFalse(RTKAgentManager.hasGeminiBeforeToolHooks(["hooks": ["AfterTool": []]]))
    }
}
