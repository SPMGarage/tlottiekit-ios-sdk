import XCTest

/// Taps every sample in the demo, like a user would, and checks that the
/// right format is reported and that the player is actually animating.
final class TLottieDemoUITests: XCTestCase {
    /// Bundled samples with the format the demo must report for each.
    private let samples: [(name: String, format: String)] = [
        ("mascot", "Lottie JSON"), ("pulse", "Lottie JSON"),
        ("cherry", "Telegram sticker"), ("duck", "Telegram sticker"),
        ("laughing", "Telegram sticker"), ("mole", "Telegram sticker"),
        ("coffee", "dotLottie"), ("pigeon", "dotLottie"), ("theming", "dotLottie"),
        ("bounce", "GIF"),
        ("cat", "MP4 / MOV video")
    ]

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testEveryFileLoadsAndPlays() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["now-playing"].waitForExistence(timeout: 15), "first file")

        for sample in samples {
            tapFile(sample.name, in: app)
            checkShowsAndPlays(sample, in: app, element: app.descendants(matching: .any)["player"])
        }
    }

    @MainActor
    func testGridPlaysManyCopies() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-grid"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["now-playing"].waitForExistence(timeout: 15), "first file")

        // A video, a GIF, a .tgs sticker and a dotLottie file.
        for sample in samples where ["cat", "bounce", "duck", "coffee"].contains(sample.name) {
            tapFile(sample.name, in: app)
            let cells = app.descendants(matching: .any).matching(identifier: "grid-cell")
            // The grid sits below the controls and is lazy: its cells only exist
            // near the screen, which is the point. Scroll down to it first.
            for _ in 0 ..< 8 where cells.count == 0 {
                app.swipeUp(velocity: .slow)
            }
            XCTAssertGreaterThanOrEqual(cells.count, 4, "\(sample.name): grid cells")
            // Every cell must show the file just picked, not the one before it.
            for index in 0 ..< cells.count {
                let shows = cells.element(boundBy: index).value as? String ?? ""
                XCTAssertTrue(shows.hasPrefix(sample.name + "."), "\(sample.name): cell \(index) shows \(shows)")
            }
            checkShowsAndPlays(sample, in: app, element: cells.element(boundBy: 0))
        }
    }

    // MARK: Helpers

    @MainActor
    private func tapFile(_ name: String, in app: XCUIApplication) {
        let button = app.buttons[name]
        scrollIntoView(button, in: app)
        button.tap()
    }

    @MainActor
    private func checkShowsAndPlays(_ sample: (name: String, format: String), in app: XCUIApplication, element: XCUIElement) {
        // "MP4 / MOV video · cat.mp4", detected from the file contents.
        let header = app.descendants(matching: .any)["now-playing"]
        let expected = NSPredicate(format: "label CONTAINS %@", "\(sample.format)")
        let named = NSPredicate(format: "label CONTAINS %@", " · \(sample.name).")
        let shown = XCTNSPredicateExpectation(
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [expected, named]), object: header
        )
        XCTAssertEqual(XCTWaiter().wait(for: [shown], timeout: 5), .completed, "\(sample.name): header says \(header.label)")
        XCTAssertFalse(app.staticTexts["error"].exists, "\(sample.name): \(app.staticTexts["error"].label)")

        // Let playback start, then two looks half a second apart must differ.
        scrollIntoView(element, in: app)
        Thread.sleep(forTimeInterval: 1)
        let first = element.screenshot()
        Thread.sleep(forTimeInterval: 0.5)
        let second = element.screenshot()
        XCTAssertNotEqual(first.pngRepresentation, second.pngRepresentation, "\(sample.name): not animating")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = sample.name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Scrolls the page, up or down, until the element is fully on screen.
    @MainActor
    private func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication) {
        let screen = app.windows.firstMatch.frame
        for _ in 0 ..< 10 where !screen.contains(element.frame) {
            if element.frame.minY < screen.midY {
                app.swipeDown(velocity: .slow)
            } else {
                app.swipeUp(velocity: .slow)
            }
        }
    }
}
