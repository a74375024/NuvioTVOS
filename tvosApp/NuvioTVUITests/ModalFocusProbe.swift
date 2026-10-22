import XCTest

/// Drives modals with real remote presses (XCUIRemote) and checks that focus
/// can move inside them and that their text fields can be reached and typed
/// into. Sweeps every row of each Settings category plus the Live TV
/// controls. Writes a log (and screenshots of problems) to $SHOT_DIR/<test>/.
@MainActor
final class ModalFocusProbe: XCTestCase {
    private var app: XCUIApplication!
    private var dir: URL!
    private var lines: [String] = []
    private var step = 0
    private var problems = 0

    override func setUp() {
        continueAfterFailure = true
        let base = ProcessInfo.processInfo.environment["SHOT_DIR"] ?? NSTemporaryDirectory()
        let testName = name.split(separator: " ").last.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "]")) } ?? "probe"
        dir = URL(fileURLWithPath: base).appendingPathComponent(testName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        note("SUMMARY problems=\(problems)")
        flush()
        app?.terminate()
    }

    // MARK: Targeted: the Xtream form end to end

    func test1XtreamFillForm() {
        openSettingsCategory("Integrations")
        guard let row = findRow("Add Account") else { return fail("no Add Account row") }
        guard focus(row, "Add Account") else { return fail("could not focus Add Account") }
        press(.select)
        sleep(2)
        snap("xtream-open")
        note("initial focus in Xtream form: \(describe(focused))")
        let fields = visibleFields()
        note("Xtream visible fields: \(fields.count)")
        XCTAssertEqual(fields.count, 4, "Xtream form shows 4 fields")
        if !isField(focused) {
            fail("Xtream form did not open on a field (\(describe(focused)))")
        } else if let first = fields.first, !first.hasFocus {
            fail("Xtream form opened on a field other than Name (\(describe(focused)))")
        }
        if app.keyboards.count > 0 || focused.label == "Keyboard" {
            fail("Xtream form opened the keyboard by itself")
        }
        // From Cancel, Up must reach the fields.
        let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel'")).firstMatch
        if focus(cancel, "Cancel") {
            press(.up)
            note("Up from Cancel -> \(describe(focused))")
            if !isField(focused) { fail("Up from Cancel did not reach a field") }
        }
        var filled = 0
        for (index, field) in fields.enumerated() {
            let text = "probe\(index)x"
            guard focus(field, "Xtream field \(index)") else {
                fail("Xtream field \(index) never took focus")
                continue
            }
            if typeInto(text, label: "xtream\(index)") { filled += 1 }
        }
        note("RESULT Xtream filled \(filled)/\(fields.count)")
        XCTAssertEqual(filled, 4, "all four Xtream fields accept text")
        // Every field filled -> Save is enabled and reachable.
        let save = app.buttons.matching(NSPredicate(format: "label == 'Save'")).firstMatch
        note("Save enabled: \(save.exists && save.isEnabled)")
        if !(save.exists && save.isEnabled) { fail("Save not enabled after filling the form") }
        else if !focus(save, "Save") { fail("Save could not take focus") }
        snap("xtream-filled")
    }

    // MARK: Sweeps

    func test2SweepIntegrations() { sweepSettings("Integrations") }
    func test3SweepAccount() { sweepSettings("Account") }
    func test4SweepAppearance() { sweepSettings("Appearance") }
    func test5SweepLayout() { sweepSettings("Layout") }
    func test6SweepPlayback() { sweepSettings("Playback") }
    func test7SweepAdvanced() { sweepSettings("Advanced") }
    func test8SweepAbout() { sweepSettings("About") }

    func test9SweepLiveTV() {
        launch("live-demo")
        for chip in ["Search", "My Lineup", "Live Events", "Genre", "Options"] {
            let button = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", chip)).firstMatch
            guard focus(button, "chip \(chip)") else { problem("could not focus Live TV chip \(chip)"); continue }
            press(.select)
            sleep(2)
            if !button.isHittable || focused.label != button.label {
                exerciseModal("Live TV › \(chip)")
                if chip == "Options" { sweepOpenModal("Live TV › Options") }
                dismiss(back: button)
            } else {
                note("chip \(chip): no modal")
            }
        }
        // Long-press menu on a channel row.
        press(.down)
        press(.down)
        let row = focused
        note("long-press on \(describe(row))")
        XCUIRemote.shared.press(.select, forDuration: 1.2)
        sleep(2)
        exerciseModal("Live TV › long-press menu")
        press(.menu)
        sleep(1)
    }

    func test10LiveTVSetup() {
        launch("live-demo-setup")
        let start = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Set Up'")).firstMatch
        if start.exists, start.isHittable, focus(start, "Set Up My Lineup") {
            press(.select)
            sleep(3)
        }
        exerciseModal("Live TV › Setup (market)")
        // Pick the first market and continue through the steps.
        press(.select)
        sleep(2)
        exerciseModal("Live TV › Setup (next step)")
    }

    // MARK: Sweep engine

    private func sweepSettings(_ category: String) {
        guard let anchor = openSettingsCategory(category) else { return }
        var seen: [String: Int] = [:]
        var stalls = 0
        for _ in 0..<60 {
            let row = focused
            guard row.exists else { problem("lost focus in \(category)"); break }
            let key = "\(row.label)|\(Int(row.frame.minX))"
            seen[key, default: 0] += 1
            if seen[key]! > 2 { break }
            if seen[key] == 1 {
                let label = row.label
                let frame = row.frame
                press(.select)
                sleep(2)
                let after = focused
                let moved = !after.exists || abs(after.frame.midY - frame.midY) > 30 || abs(after.frame.midX - frame.midX) > 60
                if !anchor.isHittable || moved {
                    exerciseModal("\(category) › \(label.prefix(50))")
                    closeModal(row: frame, anchor: anchor)
                    if isSidebar(focused) { press(.right) }
                    if !near(focused, frame) {
                        note("  focus after closing: \(describe(focused))")
                        let again = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
                        if again.exists { _ = focus(again, "row \(label.prefix(40))") }
                    }
                } else {
                    note("row '\(label.prefix(60))': no modal")
                    if focused.elementType == .button, isSidebar(focused) { press(.right) }
                }
            }
            let before = "\(focused.label)|\(focused.frame)"
            press(.down)
            if "\(focused.label)|\(focused.frame)" == before {
                stalls += 1
                if stalls >= 2 { break }
            } else {
                stalls = 0
            }
        }
        note("swept \(seen.count) rows in \(category)")
    }

    /// Inside an already-open modal: open each of its rows that opens another
    /// modal (one level), e.g. Live TV Options.
    private func sweepOpenModal(_ name: String) {
        var seen = Set<String>()
        for _ in 0..<8 {
            let row = focused
            let key = "\(row.label)|\(row.frame)"
            if seen.contains(key) { break }
            seen.insert(key)
            press(.down)
        }
        note("\(name): \(seen.count) rows")
    }

    /// Checks focus can move inside the open modal, and that any text field
    /// in it can be reached and typed into.
    private func exerciseModal(_ name: String) {
        let initial = focused
        note("MODAL \(name)")
        note("  opens on: \(describe(initial))")
        if !initial.exists { problem("\(name): nothing focused when opened") }
        let fields = visibleFields()
        let focusables = app.descendants(matching: .any)
            .matching(NSPredicate(format: "(elementType == %d OR elementType == %d OR elementType == %d OR elementType == %d) AND enabled == true",
                                  XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.textField.rawValue,
                                  XCUIElement.ElementType.secureTextField.rawValue, XCUIElement.ElementType.cell.rawValue))
            .allElementsBoundByIndex.filter { $0.isHittable }
        var reached = Set<String>()
        var reachedFields = 0
        func record() {
            let f = focused
            let key = "\(f.elementType.rawValue)|\(f.label)|\(Int(f.frame.minX)),\(Int(f.frame.minY))"
            if reached.insert(key).inserted, isField(f) { reachedFields += 1 }
        }
        record()
        for _ in 0..<3 { press(.up); record() }
        for _ in 0..<5 { press(.down); record() }
        press(.left); record()
        press(.right); record()
        for _ in 0..<3 { press(.up); record() }
        note("  focusable on screen: \(focusables.count), distinct focus positions reached: \(reached.count), fields visible: \(fields.count), fields reached: \(reachedFields)")
        if focusables.count > 1 && reached.count <= 1 {
            problem("\(name): focus stuck on \(describe(initial))")
        }
        if !fields.isEmpty && reachedFields == 0 {
            problem("\(name): \(fields.count) text field(s) but none could be reached")
        }
        if let field = fields.first, reachedFields > 0 {
            if focus(field, "\(name) first field") {
                _ = typeInto("zq\(step)", label: "type")
            } else {
                problem("\(name): first field could not take focus")
            }
        }
    }

    private func near(_ element: XCUIElement, _ frame: CGRect) -> Bool {
        element.exists && abs(element.frame.midY - frame.midY) <= 30 && abs(element.frame.midX - frame.midX) <= 60
    }

    /// Menu until focus is back on the row that opened the modal.
    private func closeModal(row frame: CGRect, anchor: XCUIElement) {
        for _ in 0..<3 {
            press(.menu)
            sleep(1)
            if near(focused, frame) || isSidebar(focused) && anchor.isHittable { return }
            if anchor.isHittable && !near(focused, frame) && focused.exists && focused.frame.minX > 400 {
                // Closed; focus landed on another row.
                return
            }
        }
        problem("could not close modal with Menu (focus: \(describe(focused)))")
    }

    private func dismiss(back anchor: XCUIElement) {
        for _ in 0..<4 {
            if anchor.isHittable { return }
            press(.menu)
            sleep(1)
        }
        if !anchor.isHittable { problem("could not close modal with Menu"); snap("stuck-open") }
    }

    @discardableResult
    private func typeInto(_ text: String, label: String) -> Bool {
        press(.select)
        sleep(2)
        app.typeText(text)
        sleep(1)
        press(.menu)
        sleep(2)
        let shown = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).count > 0
            || app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS %@", text)).count > 0
            || app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", String(repeating: "•", count: text.count))).count > 0
        note("  typed '\(text)' -> shown: \(shown)")
        if !shown { problem("typed text did not show (\(label))") }
        return shown
    }

    // MARK: Navigation

    @discardableResult
    private func openSettingsCategory(_ name: String) -> XCUIElement? {
        launch("settings")
        // Walk the sidebar with the remote (lower categories aren't in the
        // tree until scrolled to).
        for _ in 0..<3 where !isSidebar(focused) { press(.left) }
        for _ in 0..<10 { press(.up) }
        // Sidebar pills have no accessibility label of their own; match the
        // focused pill to the element carrying the category's title.
        var found = false
        var category = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", name)).firstMatch
        for _ in 0..<14 {
            let title = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH[c] %@", name)).firstMatch
            let current = focused
            if title.exists, current.exists, current.frame.insetBy(dx: -4, dy: -4).contains(CGPoint(x: title.frame.midX, y: title.frame.midY)) {
                found = true
                category = title
                break
            }
            press(.down)
        }
        guard found else {
            problem("no settings category \(name) (sidebar focus: \(describe(focused)))")
            return nil
        }
        press(.select)
        sleep(1)
        press(.right)
        sleep(1)
        note("entered \(name): \(describe(focused))")
        return category
    }

    private func findRow(_ text: String) -> XCUIElement? {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
        return row.waitForExistence(timeout: 5) ? row : nil
    }

    private func isSidebar(_ element: XCUIElement) -> Bool {
        element.frame.minX < 400
    }

    private func isField(_ element: XCUIElement) -> Bool {
        element.elementType == .textField || element.elementType == .secureTextField
    }

    private func visibleFields() -> [XCUIElement] {
        (app.textFields.allElementsBoundByIndex + app.secureTextFields.allElementsBoundByIndex)
            .filter { $0.isHittable && $0.frame.minX >= 0 && $0.frame.minY >= 0 }
    }

    private func launch(_ tour: String) {
        app = XCUIApplication()
        app.launchArguments = ["-NuvioScreenTour", tour]
        app.launch()
        sleep(14)
    }

    private var focused: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }

    private func describe(_ element: XCUIElement) -> String {
        guard element.exists else { return "(nothing focused)" }
        return "type=\(element.elementType.rawValue) label='\(element.label.prefix(60))' frame=\(Int(element.frame.minX)),\(Int(element.frame.minY)) \(Int(element.frame.width))x\(Int(element.frame.height))"
    }

    private func press(_ button: XCUIRemote.Button) {
        XCUIRemote.shared.press(button)
        usleep(600_000)
    }

    private func focus(_ target: XCUIElement, _ what: String) -> Bool {
        guard target.waitForExistence(timeout: 8) else {
            note("MISSING \(what)")
            return false
        }
        var tried = Set<String>()
        for _ in 0..<45 {
            if target.hasFocus { return true }
            let current = focused
            guard current.exists else {
                note("nothing focused while seeking \(what)")
                return false
            }
            let from = current.frame, to = target.frame
            let dx = to.midX - from.midX, dy = to.midY - from.midY
            let horizontal: XCUIRemote.Button = dx >= 0 ? .right : .left
            let vertical: XCUIRemote.Button = dy >= 0 ? .down : .up
            let preferred: [XCUIRemote.Button] = abs(dy) > 12 ? [vertical, horizontal] : [horizontal, vertical]
            let state = "\(current.label)|\(from)"
            guard let move = (preferred + [.up, .down, .left, .right]).first(where: { !tried.contains("\(state)|\($0.rawValue)") }) else { break }
            tried.insert("\(state)|\(move.rawValue)")
            press(move)
        }
        note("FAILED to focus \(what); focus is on \(describe(focused))")
        return false
    }

    // MARK: Output

    private func problem(_ text: String) {
        problems += 1
        note("PROBLEM: \(text)")
        snap("problem")
        XCTFail(text)
    }

    private func fail(_ text: String) {
        problem(text)
    }

    private func snap(_ label: String) {
        step += 1
        let file = String(format: "%03d-%@", step, label)
        let shot = XCUIScreen.main.screenshot()
        try? shot.pngRepresentation.write(to: dir.appendingPathComponent(file + ".png"))
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = file
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func note(_ text: String) {
        lines.append(text)
        print("PROBE \(text)")
        flush()
    }

    private func flush() {
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
    }
}
