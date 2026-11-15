import XCTest
@testable import BenjiCore

final class FigureSettingTests: XCTestCase {
    func testOnUnlessTurnedOff() {
        XCTAssertTrue(FigureSetting.isOn(from: nil))
        XCTAssertTrue(FigureSetting.isOn(from: [1]))
        XCTAssertTrue(FigureSetting.isOn(from: true))
        XCTAssertTrue(FigureSetting.isOn(from: NSNumber(value: 1)))
        XCTAssertTrue(FigureSetting.isOn(from: "YES"))
        XCTAssertTrue(FigureSetting.isOn(from: "true"))
        XCTAssertTrue(FigureSetting.isOn(from: "1"))
        XCTAssertFalse(FigureSetting.isOn(from: false))
        XCTAssertFalse(FigureSetting.isOn(from: NSNumber(value: 0)))
        XCTAssertFalse(FigureSetting.isOn(from: "no"))
        XCTAssertFalse(FigureSetting.isOn(from: "0"))
    }

    func testTheKeyStays() {
        XCTAssertEqual(FigureSetting.defaultsKey, "figureStage")
    }

    func testNotices() {
        XCTAssertTrue(FigureSetting.notice(on: true).hasPrefix("3D drawings are on from your next message"))
        XCTAssertEqual(FigureSetting.notice(on: false), "3D drawings are off from your next message.")
    }
}
