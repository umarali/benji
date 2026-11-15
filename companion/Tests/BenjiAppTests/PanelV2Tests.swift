import XCTest
@testable import BenjiApp
import BenjiCore

/// The panel's defaults in the app's coordinator: Screen starts On and stays as chosen, Expand is remembered.
final class PanelV2Tests: XCTestCase {
    func suite() -> UserDefaults { UserDefaults(suiteName: "benji-panel-v2-\(UUID().uuidString)")! }

    func testAFreshStoreStartsOnAndKeepsAChoice() {
        let defaults = suite()
        XCTAssertEqual(ScreenModeStore(defaults: defaults).mode, .on)
        XCTAssertEqual(defaults.string(forKey: ScreenModeState.defaultsKey), "on", "saved at once")
        ScreenModeStore(defaults: defaults).choose(.ask)
        XCTAssertEqual(ScreenModeStore(defaults: defaults).mode, .ask, "the next launch keeps Ask")
        ScreenModeStore(defaults: defaults).choose(.on)
        XCTAssertEqual(ScreenModeStore(defaults: defaults).mode, .on, "and On, which no longer lapses at launch")
    }

    func testExpandIsRemembered() {
        let defaults = suite()
        let model = CompanionModel(backend: FakeBackend(), screenMode: ScreenModeStore(defaults: defaults))
        let start = model.panelExpanded
        model.setPanelExpanded(!start, defaults: defaults)
        XCTAssertEqual(model.panelExpanded, !start)
        XCTAssertEqual(defaults.bool(forKey: PanelGeometry.expandedKey), !start)
        model.setPanelExpanded(false, defaults: defaults)
        XCTAssertFalse(model.panelExpanded)
        XCTAssertFalse(defaults.bool(forKey: PanelGeometry.expandedKey))
    }
}
