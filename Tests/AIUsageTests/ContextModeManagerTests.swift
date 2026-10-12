import XCTest
@testable import AIUsage

final class ContextModeManagerTests: XCTestCase {
    func testPluginDetectionMatchesOnlyExactPluginIdentifier() {
        XCTAssertTrue(ContextModeManager.containsPlugin("context-mode@context-mode (v1.2.0)", pluginID: ContextModeManager.pluginID))
        XCTAssertTrue(ContextModeManager.containsPlugin("❯ context-mode@context-mode enabled", pluginID: ContextModeManager.pluginID))
        XCTAssertFalse(ContextModeManager.containsPlugin("other-context-mode@context-mode", pluginID: ContextModeManager.pluginID))
        XCTAssertFalse(ContextModeManager.containsPlugin("context-mode@another-marketplace", pluginID: ContextModeManager.pluginID))
    }

    func testMarketplaceDetectionMatchesMarketplaceName() {
        XCTAssertTrue(ContextModeManager.containsMarketplace("❯ context-mode  mksglu/context-mode", name: "context-mode"))
        XCTAssertFalse(ContextModeManager.containsMarketplace("another-context-mode", name: "context-mode"))
    }

    func testOtherMarketplacePluginsPreventMarketplaceRemoval() {
        XCTAssertFalse(ContextModeManager.hasOtherPlugins("context-mode@context-mode", using: "context-mode", excluding: ContextModeManager.pluginID))
        XCTAssertTrue(ContextModeManager.hasOtherPlugins("some-plugin@context-mode", using: "context-mode", excluding: ContextModeManager.pluginID))
    }

    func testNodeVersionRequirement() {
        XCTAssertTrue(ContextModeManager.supportsNodeVersion("v22.5.0"))
        XCTAssertTrue(ContextModeManager.supportsNodeVersion("v24.1.2"))
        XCTAssertFalse(ContextModeManager.supportsNodeVersion("v22.4.9"))
        XCTAssertFalse(ContextModeManager.supportsNodeVersion("v20.19.0"))
        XCTAssertFalse(ContextModeManager.supportsNodeVersion("not a version"))
    }
}
