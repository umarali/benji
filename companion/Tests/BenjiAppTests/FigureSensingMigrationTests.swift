import Foundation
import XCTest
@testable import BenjiApp
import BenjiCore

/// "Draw Things in 3D" became an off switch, on by default (chilly-whiteboard): an "off" stored
/// under the old opt-in meaning is cleared once; what the user sets afterwards is kept.
final class FigureSensingMigrationTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "benji-figure-sensing-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testAnOldOffIsClearedOnceThenKept() {
        let d = suite()
        d.set(false, forKey: FigureSetting.defaultsKey)
        DefaultsMigration.figureSensing(d)
        XCTAssertNil(d.object(forKey: FigureSetting.defaultsKey))
        XCTAssertTrue(FigureSetting.isOn(from: d.object(forKey: FigureSetting.defaultsKey)))
        d.set(false, forKey: FigureSetting.defaultsKey)   // the user turns it off afterwards
        DefaultsMigration.figureSensing(d)
        XCTAssertEqual(d.object(forKey: FigureSetting.defaultsKey) as? Bool, false)
    }

    func testOnOrUnsetIsLeftAlone() {
        let d = suite()
        d.set(true, forKey: FigureSetting.defaultsKey)
        DefaultsMigration.figureSensing(d)
        XCTAssertEqual(d.object(forKey: FigureSetting.defaultsKey) as? Bool, true)
        let e = suite()
        DefaultsMigration.figureSensing(e)
        XCTAssertNil(e.object(forKey: FigureSetting.defaultsKey))
        XCTAssertTrue(e.bool(forKey: FigureSetting.migrationKey))
    }
}
