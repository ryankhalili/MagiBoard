import XCTest

@MainActor
final class CanvasStudioUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["tab_draw"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["tool_pen"].waitForExistence(timeout: 5))
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    private func settingsCategory(_ key: String, in app: XCUIApplication) {
        let category = app.descendants(matching: .any).matching(identifier: "settings_category_" + key).firstMatch
        if !category.waitForExistence(timeout: 2) || !category.isHittable {
            // NavigationSplitView may collapse its sidebar inside a narrow presentation.
            // Scope to the sheet's navigation bar: the document also has a Settings button.
            for label in ["BackButton", "Settings", "Sidebar", "Show Sidebar"] {
                let toggle = app.navigationBars.buttons[label].firstMatch
                if toggle.exists && toggle.isHittable { toggle.tap(); break }
            }
        }
        XCTAssertTrue(category.waitForExistence(timeout: 4))
        XCTAssertTrue(category.isHittable)
        category.tap()
    }

    private func keepScreenshot(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func expectLibraryClosed(_ close: XCUIElement) {
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 4), .completed)
    }

    private func setSwitch(_ control: XCUIElement, enabled: Bool) {
        let expected = enabled ? "1" : "0"
        if control.value as? String != expected {
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        let predicate = NSPredicate(format: "value == %@", expected)
        let changed = XCTNSPredicateExpectation(predicate: predicate, object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }

    func testGraphParameterChangeAndUndo() {
        let app = launch()
        app.buttons["insert"].tap()
        let graph = app.buttons["Graph"]
        XCTAssertTrue(graph.waitForExistence(timeout: 4))
        graph.tap()
        let inspector = app.descendants(matching: .any).matching(identifier: "objectInspector").firstMatch
        XCTAssertTrue(inspector.waitForExistence(timeout: 4))
        let amplitude = app.sliders.firstMatch
        XCTAssertTrue(amplitude.waitForExistence(timeout: 4))
        let previous = amplitude.value as? String
        amplitude.adjust(toNormalizedSliderPosition: 0.8)
        XCTAssertNotEqual(amplitude.value as? String, previous)
        let undo = app.buttons["undo"]
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        XCTAssertTrue(app.buttons["Redo"].isEnabled)
        XCTAssertTrue(app.buttons["insert"].exists)
    }

    func testOfflineMagicCreatesEditableTriangle() {
        let app = launch()
        app.buttons["magic"].tap()
        XCTAssertTrue(app.staticTexts["OFFLINE COMMANDS"].waitForExistence(timeout: 3))
        let prompt = app.descendants(matching: .any).matching(identifier: "magicPrompt").firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 3))
        prompt.tap()
        prompt.typeText("Create a green triangle with angles 49 and 52")
        app.buttons["magicSend"].tap()
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Offline command applied")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "objectInspector").firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["Object name"].value as? String, "Triangle")
        XCTAssertTrue(app.buttons["undo"].isEnabled)
    }

    func testFingerDrawingCreatesUndoableInk() {
        let app = launch()
        XCTAssertFalse(app.buttons["undo"].isEnabled)
        app.buttons["settings"].tap()
        settingsCategory("canvas", in: app)
        let finger = app.switches["Draw with a finger"]
        reveal(finger, in: app)
        XCTAssertTrue(finger.waitForExistence(timeout: 4))
        setSwitch(finger, enabled: true)
        app.buttons["Done"].tap()
        app.buttons["tool_pen"].tap()
        let canvas = app.otherElements["infiniteCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.72))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.72))
        start.press(forDuration: 0.1, thenDragTo: end)
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: app.buttons["undo"])
        waitForExpectations(timeout: 5)
        app.buttons["undo"].tap()
        XCTAssertTrue(app.buttons["Redo"].isEnabled)
    }

    func testSettingsPersistAndAICanBeDisabled() {
        let app = launch()
        app.buttons["settings"].tap()
        settingsCategory("magic", in: app)
        let ai = app.switches["Magic Pen & AI"]
        XCTAssertTrue(ai.waitForExistence(timeout: 4))
        setSwitch(ai, enabled: false)
        app.buttons["Done"].tap()
        XCTAssertFalse(app.buttons["magic"].exists)

        app.buttons["settings"].tap()
        settingsCategory("canvas", in: app)
        let dark = app.switches["Dark appearance"]
        reveal(dark, in: app)
        setSwitch(dark, enabled: true)
        app.buttons["Done"].tap()
        app.buttons["settings"].tap()
        settingsCategory("canvas", in: app)
        reveal(dark, in: app)
        XCTAssertEqual(dark.value as? String, "1")
        app.buttons["Done"].tap()
        XCTAssertFalse(app.buttons["magic"].exists)
    }

    func testToolbarCollapseAndPaperSetup() {
        let app = launch()
        let pen = app.buttons["tool_pen"]
        XCTAssertTrue(pen.exists)
        app.buttons["toggleToolbar"].tap()
        XCTAssertFalse(pen.exists)
        XCTAssertTrue(app.buttons["tab_home"].exists)
        XCTAssertTrue(app.buttons["tab_insert"].exists)
        XCTAssertTrue(app.buttons["tab_view"].exists)
        XCTAssertEqual(app.buttons["toggleToolbar"].label, "Show ribbon")
        app.buttons["toggleToolbar"].tap()
        XCTAssertTrue(pen.waitForExistence(timeout: 3))
        let setup = app.buttons["pageSetup"]
        setup.tap()
        let grid = app.buttons["Grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 3))
        grid.tap()
        XCTAssertEqual(setup.value as? String, "grid")
        setup.tap()
        app.buttons["Insert A4 page"].tap()
        let name = app.textFields["Object name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        XCTAssertEqual(name.value as? String, "Page 1")
        XCTAssertTrue(app.buttons["undo"].isEnabled)
    }

    func testHeaderCompactsIndependentlyOfRibbonAndPersistsInSettings() {
        let app = launch()
        let tab = app.buttons["tab_draw"]
        let expandedHeight = tab.frame.height
        let toggle = app.buttons["toggleHeader"]
        XCTAssertEqual(toggle.label, "Compact title bar")
        toggle.tap()
        let compact = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            tab.frame.height < expandedHeight - 10
        }, object: tab)
        XCTAssertEqual(XCTWaiter.wait(for: [compact], timeout: 4), .completed)
        XCTAssertEqual(toggle.label, "Expand title bar")
        XCTAssertTrue(app.buttons["tool_pen"].exists, "Compacting the title bar must not hide writing tools")
        app.buttons["settings"].tap()
        settingsCategory("canvas", in: app)
        let setting = app.switches["Compact header"]
        XCTAssertTrue(setting.waitForExistence(timeout: 3))
        XCTAssertEqual(setting.value as? String, "1")
        app.buttons["Done"].tap()
        keepScreenshot("Compact header with writing ribbon", in: app)
        toggle.tap()
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(tab.frame.height - expandedHeight) < 1
        }, object: tab)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 4), .completed)
    }

    func testRibbonTabsExposeWorkingHomeInsertAndViewActions() throws {
        let app = launch()
        let canvas = app.otherElements["infiniteCanvas"]
        app.buttons["tab_home"].tap()
        XCTAssertTrue(app.buttons["Paste"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["tool_pen"].exists)
        XCTAssertFalse(app.buttons["undo"].isEnabled)
        app.buttons["tab_insert"].tap()
        let graph = app.buttons["Graph"]
        XCTAssertTrue(graph.waitForExistence(timeout: 3))
        graph.tap()
        let objectName = app.textFields["Object name"]
        XCTAssertTrue(objectName.waitForExistence(timeout: 3))
        XCTAssertEqual(objectName.value as? String, "Graph")
        app.buttons["tab_home"].tap()
        XCTAssertTrue(app.buttons["undo"].isEnabled)
        app.buttons["undo"].tap()
        XCTAssertTrue(app.buttons["Redo"].isEnabled)
        app.buttons["tab_view"].tap()
        let actualSize = app.buttons["100%"]
        XCTAssertTrue(actualSize.waitForExistence(timeout: 3))
        actualSize.tap()
        let reset = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            abs((canvasState(canvas)["zoom"] ?? 0) - 1) < 0.001
        }, object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [reset], timeout: 4), .completed)
        XCTAssertTrue(app.buttons["pageSetup"].exists)
        keepScreenshot("View ribbon at actual size", in: app)
        app.buttons["tab_draw"].tap()
        XCTAssertTrue(app.buttons["tool_pen"].waitForExistence(timeout: 3))
    }

    func testSidebarAddsAndNavigatesToCanvasPage() throws {
        let app = launch()
        let canvas = app.otherElements["infiniteCanvas"]
        app.buttons["notebooks"].tap()
        let close = app.buttons["closeLibrary"]
        XCTAssertTrue(close.waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["newNotebook"].exists)
        XCTAssertTrue(app.buttons["tab_draw"].exists, "Library should leave the document header visible")
        let newPage = app.buttons["newPage"]
        XCTAssertTrue(newPage.waitForExistence(timeout: 3))
        newPage.tap()
        expectLibraryClosed(close)
        let objectName = app.textFields["Object name"]
        XCTAssertTrue(objectName.waitForExistence(timeout: 4))
        XCTAssertEqual(objectName.value as? String, "Page 1")
        let focused = canvasState(canvas)
        let focusedX = try XCTUnwrap(focused["x"]), focusedY = try XCTUnwrap(focused["y"])
        let pageX = try XCTUnwrap(focused["selectedX"]), pageY = try XCTUnwrap(focused["selectedY"])
        app.buttons["tool_hand"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.62)).press(forDuration: 0.1,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.72)))
        let moved = canvasState(canvas)
        XCTAssertGreaterThan(hypot(try XCTUnwrap(moved["x"]) - focusedX, try XCTUnwrap(moved["y"]) - focusedY), 30)
        app.buttons["notebooks"].tap()
        let row = app.buttons["Page 1"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        expectLibraryClosed(close)
        let refocused = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            let state = canvasState(canvas)
            guard let x = state["x"], let y = state["y"] else { return false }
            return hypot(x - focusedX, y - focusedY) < 3 && state["selected"] == 1 && state["selectedX"] == pageX && state["selectedY"] == pageY
        }, object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [refocused], timeout: 4), .completed, "Page selection must move the actual canvas back to that page")
        XCTAssertTrue(objectName.waitForExistence(timeout: 3))
        XCTAssertEqual(objectName.value as? String, "Page 1")
        keepScreenshot("Page selected and focused from library", in: app)
    }

    private func canvasState(_ canvas: XCUIElement) -> [String: Double] {
        guard let raw = canvas.value as? String else { return [:] }
        var state: [String: Double] = [:]
        for part in raw.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2, let number = Double(pair[1]) { state[String(pair[0])] = number }
        }
        return state
    }

    private func coordinate(worldX: Double, worldY: Double, on canvas: XCUIElement) throws -> XCUICoordinate {
        let state = canvasState(canvas)
        let x = try XCTUnwrap(state["x"])
        let y = try XCTUnwrap(state["y"])
        let zoom = try XCTUnwrap(state["zoom"])
        return canvas.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: (worldX - x) * zoom, dy: (worldY - y) * zoom))
    }

    func testTapSelectDragAndUndoPreserveCanvasPosition() throws {
        let app = launch()
        let canvas = app.otherElements["infiniteCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 4))
        app.buttons["tool_select"].tap()
        let camera = canvasState(canvas)
        try coordinate(worldX: 280, worldY: 440, on: canvas).tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            canvasState(canvas)["selected"] == 1
        }, object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 4), .completed)
        XCTAssertEqual(app.textFields["Object name"].value as? String, "A triangle with exact angles")
        let original = canvasState(canvas)
        let originalX = try XCTUnwrap(original["selectedX"])
        let originalY = try XCTUnwrap(original["selectedY"])
        try coordinate(worldX: 280, worldY: 440, on: canvas).press(forDuration: 0.1,
            thenDragTo: coordinate(worldX: 400, worldY: 490, on: canvas))
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            let state = canvasState(canvas)
            return (state["selectedX"] ?? originalX) > originalX + 60 && (state["selectedY"] ?? originalY) > originalY + 10
        }, object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 4), .completed)
        let after = canvasState(canvas)
        XCTAssertEqual(try XCTUnwrap(after["x"]), try XCTUnwrap(camera["x"]), accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(after["y"]), try XCTUnwrap(camera["y"]), accuracy: 1)
        XCTAssertEqual(after["strokes"], camera["strokes"])
        XCTAssertTrue(app.buttons["undo"].isEnabled)
        app.buttons["undo"].tap()
        try coordinate(worldX: 280, worldY: 440, on: canvas).tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            let state = canvasState(canvas)
            return state["selected"] == 1 && state["selectedX"] == originalX && state["selectedY"] == originalY
        }, object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 4), .completed)
    }

    private func expectPan(_ canvas: XCUIElement, from start: CGVector, to end: CGVector) throws {
        let before = canvasState(canvas)
        let x = try XCTUnwrap(before["x"], "Canvas must expose actual world-coordinate viewport state")
        let y = try XCTUnwrap(before["y"])
        canvas.coordinate(withNormalizedOffset: start).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: end))
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            let after = canvasState(canvas)
            guard let nextX = after["x"], let nextY = after["y"] else { return false }
            return hypot(nextX - x, nextY - y) > 20
        }, object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed, "Dragging should actually change the world viewport")
        let after = canvasState(canvas)
        XCTAssertEqual(after["strokes"], before["strokes"], "Navigation must not draw ink")
        XCTAssertEqual(after["selected"], 0, "Navigation must not select an object")
    }

    func testFingerAndHandPanMoveCanvasWithoutDrawingOrSelecting() throws {
        let app = launch()
        let canvas = app.otherElements["infiniteCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["undo"].isEnabled)
        app.buttons["tool_pen"].tap()
        // Pencil-only writing leaves a finger free to navigate.
        try expectPan(canvas, from: CGVector(dx: 0.48, dy: 0.72), to: CGVector(dx: 0.70, dy: 0.60))
        XCTAssertFalse(app.buttons["undo"].isEnabled)
        app.buttons["tool_hand"].tap()
        try expectPan(canvas, from: CGVector(dx: 0.70, dy: 0.65), to: CGVector(dx: 0.46, dy: 0.75))
        XCTAssertFalse(app.buttons["undo"].isEnabled)

        // Changing back from navigation to writing must restore the drawing recognizer.
        app.buttons["settings"].tap()
        settingsCategory("canvas", in: app)
        let finger = app.switches["Draw with a finger"]
        reveal(finger, in: app)
        setSwitch(finger, enabled: true)
        app.buttons["Done"].tap()
        app.buttons["tool_pen"].tap()
        let drawingStartState = canvasState(canvas)
        let before = try XCTUnwrap(drawingStartState["strokes"])
        let zoom = try XCTUnwrap(drawingStartState["zoom"])
        let drawingStartX = try XCTUnwrap(drawingStartState["x"]) + Double(canvas.frame.width) * 0.23 / zoom
        let drawingStartY = try XCTUnwrap(drawingStartState["y"]) + Double(canvas.frame.height) * 0.70 / zoom
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.23, dy: 0.70)).press(forDuration: 0.1,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.44, dy: 0.70)))
        let drawn = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            (canvasState(canvas)["strokes"] ?? before) > before
        }, object: canvas)
        let drawingResult = XCTWaiter.wait(for: [drawn], timeout: 5)
        XCTAssertEqual(drawingResult, .completed,
            "Stroke count before=\(before), startWorld=(\(drawingStartX),\(drawingStartY)), initialState=\(drawingStartState), current=\(canvas.value as? String ?? "missing"), undoEnabled=\(app.buttons["undo"].isEnabled)")
        XCTAssertTrue(app.buttons["undo"].isEnabled)
    }
}
