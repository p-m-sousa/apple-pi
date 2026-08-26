import Foundation
import XCTest

final class ApplePiSmokeUITests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    private var didLaunchApplication = false

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if didLaunchApplication {
            MainActor.assumeIsolated {
                let application = XCUIApplication()
                if application.state != .notRunning {
                    application.terminate()
                }
            }
            didLaunchApplication = false
        }
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    @MainActor
    func testFirstRunSetupCanBeCompleted() throws {
        let app = launch(skipOnboarding: false)
        XCTAssertTrue(app.staticTexts["Set up ApplePi"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["ApplePi does not store provider credentials."].exists)
        XCTAssertTrue(app.staticTexts["Not found"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Bundled fallback will be used"].exists)

        let installPi = element(in: app, identifier: "applepi.onboarding.install-pi")
        let retryRuntime = element(in: app, identifier: "applepi.onboarding.retry-runtime")
        let configureProvider = element(in: app, identifier: "applepi.onboarding.configure-provider")
        XCTAssertTrue(installPi.waitForExistence(timeout: 3))
        XCTAssertTrue(retryRuntime.waitForExistence(timeout: 3))
        XCTAssertTrue(configureProvider.waitForExistence(timeout: 3))
        XCTAssertFalse(configureProvider.isEnabled)

        retryRuntime.click()
        XCTAssertTrue(app.staticTexts["Not found"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["ApplePi"].exists)

        let continueButton = element(in: app, identifier: "applepi.onboarding.continue")
        XCTAssertTrue(continueButton.waitForExistence(timeout: 3))
        continueButton.click()
        XCTAssertTrue(app.staticTexts["What are we building?"].waitForExistence(timeout: 5))
        XCTAssertFalse(continueButton.exists)
    }

    @MainActor
    func testCreateTaskAndComposeWithoutInvokingAProvider() throws {
        let app = launch()
        XCTAssertTrue(element(in: app, identifier: "applepi.sidebar").waitForExistence(timeout: 10))

        clickAddTask(in: app)

        let editor = element(in: app, identifier: "applepi.composer-text-view")
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("Verify the native composer")

        let send = element(in: app, identifier: "applepi.send")
        XCTAssertTrue(send.isEnabled)
        XCTAssertTrue(element(in: app, identifier: "applepi.transcript").exists)
    }

    @MainActor
    func testUnsavedDraftCanBeMovedToTrash() throws {
        let app = launch()
        XCTAssertTrue(element(in: app, identifier: "applepi.sidebar").waitForExistence(timeout: 10))

        clickAddTask(in: app)

        let draftRow = draftRow(in: app)
        XCTAssertTrue(draftRow.waitForExistence(timeout: 5))

        draftRow.rightClick()
        let trashMenuItem = app.menuItems["Move to Trash…"].firstMatch
        XCTAssertTrue(trashMenuItem.waitForExistence(timeout: 3))
        trashMenuItem.click()

        let confirmButton = app.sheets.buttons["Move to Trash"].firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 3))
        confirmButton.click()

        XCTAssertTrue(draftRow.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No tasks"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["What are we building?"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testUntouchedNewTaskDisappearsAfterNavigatingAway() throws {
        let app = launch()
        clickAddTask(in: app)

        let draftRow = draftRow(in: app)
        XCTAssertTrue(draftRow.waitForExistence(timeout: 5))

        let extensionsRow = element(in: app, identifier: "applepi.extensions-navigation")
        XCTAssertTrue(extensionsRow.waitForExistence(timeout: 3))
        extensionsRow.click()

        XCTAssertTrue(draftRow.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.alerts["ApplePi"].exists)
    }

    @MainActor
    func testTypedTaskDraftPersistsAndRestoresAfterNavigation() throws {
        let app = launch()
        clickAddTask(in: app)

        let editor = element(in: app, identifier: "applepi.composer-text-view")
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("Remember this draft")

        let draftRow = draftRow(in: app)
        XCTAssertTrue(draftRow.waitForExistence(timeout: 3))

        let extensionsRow = element(in: app, identifier: "applepi.extensions-navigation")
        XCTAssertTrue(extensionsRow.waitForExistence(timeout: 3))
        extensionsRow.click()

        XCTAssertTrue(draftRow.exists)
        draftRow.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Remember this draft")
        XCTAssertFalse(app.alerts["ApplePi"].exists)
    }

    @MainActor
    func testSidebarUsesProjectsAndTasksHierarchy() throws {
        let app = launch()
        movePointerAwayFromSidebar(in: app)

        let appTitle = element(in: app, identifier: "applepi.app-title")
        let projectsHeader = projectsHeaderElement(in: app)
        let tasksHeader = tasksHeaderElement(in: app)
        let extensionsNavigation = element(in: app, identifier: "applepi.extensions-navigation")
        let settingsNavigation = element(in: app, identifier: "applepi.settings-navigation")
        XCTAssertTrue(appTitle.waitForExistence(timeout: 10))
        XCTAssertTrue(projectsHeader.waitForExistence(timeout: 10))
        XCTAssertTrue(tasksHeader.waitForExistence(timeout: 3))
        XCTAssertTrue(extensionsNavigation.waitForExistence(timeout: 3))
        XCTAssertTrue(settingsNavigation.waitForExistence(timeout: 3))
        XCTAssertTrue(projectsHeader.label.contains("Projects"))
        XCTAssertTrue(tasksHeader.label.contains("Tasks"))
        XCTAssertEqual(appTitle.frame.minX, projectsHeader.frame.minX, accuracy: 1)
        XCTAssertEqual(appTitle.frame.minX, tasksHeader.frame.minX, accuracy: 1)
        XCTAssertEqual(extensionsNavigation.frame.minX, projectsHeader.frame.minX, accuracy: 1)
        XCTAssertEqual(settingsNavigation.frame.minX, projectsHeader.frame.minX, accuracy: 1)
        XCTAssertGreaterThan(extensionsNavigation.frame.midY, tasksHeader.frame.midY)
        XCTAssertLessThan(extensionsNavigation.frame.midY, settingsNavigation.frame.midY)
        XCTAssertFalse(appTitle.images["chevron.down"].exists)
        XCTAssertFalse(app.staticTexts["Chats"].exists)
        capture(app, named: "Sidebar navigation footer")
    }

    @MainActor
    func testSidebarSearchOpensWithKeyboardFocusAndDismisses() throws {
        let app = launch()
        let searchButton = element(in: app, identifier: "applepi.search-button")
        XCTAssertTrue(searchButton.waitForExistence(timeout: 10))

        searchButton.click()

        let searchField = element(in: app, identifier: "applepi.search-field")
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        searchField.typeText("missing task")
        XCTAssertEqual(searchField.value as? String, "missing task")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testPiTerminalTaskUnderProjectPathIsNestedUnderProject() throws {
        let project = SeedProject(
            name: "Apple Pi",
            workingDirectory: URL(filePath: "/Users/example/Projects/apple-pi", directoryHint: .isDirectory)
        )
        let app = launch(
            seededProject: project,
            seededTerminalTaskTitle: "Imported terminal task"
        )

        let importedRow = element(in: app, identifier: "applepi.session-row.terminal-session")
        let projectFolder = element(
            in: app,
            identifier: "applepi.project-folder.\(project.id.rawValue.uuidString)"
        )
        let projectsHeader = projectsHeaderElement(in: app)
        let tasksHeader = tasksHeaderElement(in: app)
        XCTAssertTrue(importedRow.waitForExistence(timeout: 10))
        XCTAssertTrue(projectFolder.waitForExistence(timeout: 3))
        XCTAssertTrue(projectsHeader.waitForExistence(timeout: 3))
        XCTAssertTrue(tasksHeader.waitForExistence(timeout: 3))
        XCTAssertEqual(projectFolder.frame.minX, projectsHeader.frame.minX + 6, accuracy: 2)
        XCTAssertLessThan(importedRow.frame.midY, tasksHeader.frame.midY)
        XCTAssertTrue(app.staticTexts["Imported terminal task"].exists)
        XCTAssertTrue(app.staticTexts["No tasks"].exists)

        clickAddTask(in: app)
        let standaloneDraft = draftRow(in: app)
        XCTAssertTrue(standaloneDraft.waitForExistence(timeout: 3))
        XCTAssertEqual(importedRow.frame.minX, standaloneDraft.frame.minX, accuracy: 2)
    }

    @MainActor
    func testProjectsHeaderOffersOrganizationAndCreateProjectControls() throws {
        let app = launch()

        let hoverTarget = projectsHeaderElement(in: app)
        XCTAssertTrue(hoverTarget.waitForExistence(timeout: 10))
        XCTAssertEqual(hoverTarget.label, "Collapse Projects")
        hoverTarget.hover()

        var projectsHeader = interactiveProjectsHeaderElement(in: app)
        XCTAssertTrue(projectsHeader.waitForExistence(timeout: 3))

        projectsHeader.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).click()
        movePointerAwayFromSidebar(in: app)

        let collapsedHeader = projectsHeaderElement(in: app)
        XCTAssertTrue(collapsedHeader.waitForExistence(timeout: 3))
        XCTAssertEqual(collapsedHeader.label, "Expand Projects")
        collapsedHeader.hover()

        projectsHeader = interactiveProjectsHeaderElement(in: app)
        XCTAssertTrue(projectsHeader.waitForExistence(timeout: 3))
        projectsHeader.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).click()
        movePointerAwayFromSidebar(in: app)

        let expandedHeader = projectsHeaderElement(in: app)
        XCTAssertTrue(expandedHeader.waitForExistence(timeout: 3))
        XCTAssertEqual(expandedHeader.label, "Collapse Projects")
        expandedHeader.hover()

        projectsHeader = interactiveProjectsHeaderElement(in: app)
        XCTAssertTrue(projectsHeader.waitForExistence(timeout: 3))
        projectsHeader.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.5)).click()
        capture(app, named: "Projects organization hover")
        app.typeKey(.escape, modifierFlags: [])

        projectsHeader.hover()
        projectsHeader.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).click()
        XCTAssertTrue(element(in: app, identifier: "applepi.create-project-sheet").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Create project"].exists)
        XCTAssertTrue(app.textFields["Project name"].exists)
        XCTAssertTrue(app.buttons["Add source folder"].exists)
        XCTAssertFalse(app.buttons["Create project"].isEnabled)
    }

    @MainActor
    func testProjectRowPopoverMenuAndEditorMatchPiFeatures() throws {
        let project = SeedProject(
            name: "Apple Pi",
            workingDirectory: URL(filePath: "/Users/example/Projects/apple-pi", directoryHint: .isDirectory)
        )
        let app = launch(seededProject: project)
        movePointerAwayFromSidebar(in: app)

        let identifierSuffix = project.id.rawValue.uuidString
        let row = element(in: app, identifier: "applepi.project-row.\(identifierSuffix)")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.hover()
        capture(app, named: "01 Project row hover")

        let folderButton = element(in: app, identifier: "applepi.project-folder.\(identifierSuffix)")
        XCTAssertEqual(folderButton.label, "Collapse Apple Pi")
        XCTAssertEqual(folderButton.value as? String, "Open folder")
        folderButton.click()
        XCTAssertEqual(folderButton.label, "Expand Apple Pi")
        XCTAssertEqual(folderButton.value as? String, "Closed folder")
        folderButton.click()
        XCTAssertEqual(folderButton.value as? String, "Open folder")

        let detailsButton = element(in: app, identifier: "applepi.project-details.\(identifierSuffix)")
        XCTAssertTrue(detailsButton.exists)
        detailsButton.click()
        XCTAssertTrue(element(in: app, identifier: "applepi.project-details-card").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["0 tasks"].exists)
        XCTAssertTrue(app.staticTexts["apple-pi"].exists)
        capture(app, named: "02 Project details")
        app.typeKey(.escape, modifierFlags: [])

        row.hover()
        let menu = element(in: app, identifier: "applepi.project-menu.\(identifierSuffix)")
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.click()
        for title in [
            "Pin",
            "Edit",
            "Reveal in Finder",
            "Create permanent worktree",
            "Archive tasks",
            "Remove project",
        ] {
            XCTAssertTrue(app.menuItems[title].exists, "Missing project action: \(title)")
        }
        capture(app, named: "03 Project actions")

        app.menuItems["Edit"].click()
        XCTAssertTrue(element(in: app, identifier: "applepi.edit-project-sheet").waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["Project name"].value as? String, "Apple Pi")
        XCTAssertTrue(app.staticTexts["Source folders"].exists)
        XCTAssertTrue(app.buttons["Change source folder"].exists)
        capture(app, named: "04 Edit project")
    }

    @MainActor
    func testComposerShiftReturnAddsALineWithoutSending() throws {
        let app = launch()
        clickAddTask(in: app)

        let editor = element(in: app, identifier: "applepi.composer-text-view")
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("first line")
        editor.typeKey(.return, modifierFlags: .shift)
        editor.typeText("second line")

        XCTAssertFalse(app.staticTexts["first line\nsecond line"].exists)
        XCTAssertTrue(element(in: app, identifier: "applepi.send").isEnabled)
    }

    @MainActor
    func testExtensionsSurfaceExplainsPiAuthority() throws {
        let app = launch()
        XCTAssertTrue(element(in: app, identifier: "applepi.sidebar").waitForExistence(timeout: 10))
        let extensionsRow = element(in: app, identifier: "applepi.extensions-navigation")
        XCTAssertTrue(extensionsRow.waitForExistence(timeout: 3))
        extensionsRow.click()

        XCTAssertTrue(element(in: app, identifier: "applepi.extensions").waitForExistence(timeout: 5))
        let trustDisclosure = app.disclosureTriangles["Install only packages you trust"].firstMatch
        XCTAssertTrue(trustDisclosure.waitForExistence(timeout: 3))
        XCTAssertEqual(trustDisclosure.label, "Install only packages you trust")
    }

    @MainActor
    func testLightDarkAndSystemLaunchModes() throws {
        for appearance in ["system", "light", "dark"] {
            let app = launch(appearance: appearance)
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "Failed to launch in \(appearance) mode")
            XCTAssertTrue(element(in: app, identifier: "applepi.sidebar").exists)
            capture(app, named: "Launch appearance \(appearance)")
            app.terminate()
        }
    }

    @MainActor
    private func launch(
        skipOnboarding: Bool = true,
        appearance: String = "system",
        seededProject: SeedProject? = nil,
        seededTerminalTaskTitle: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        let sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplePiUITests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        temporaryDirectories.append(sessionDirectory)
        let dataRoot = sessionDirectory.appending(path: "app-data", directoryHint: .isDirectory)
        if let seededProject {
            let support = dataRoot.appending(path: "Application Support", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode([seededProject]) {
                try? data.write(to: support.appending(path: "projects-v1.json"), options: .atomic)
            }
            if let seededTerminalTaskTitle {
                seedTerminalSession(
                    in: sessionDirectory,
                    workingDirectory: seededProject.workingDirectory,
                    title: seededTerminalTaskTitle
                )
            }
        }
        app.launchEnvironment = [
            "PATH": "/usr/bin:/bin",
            "SHELL": "/usr/bin/false",
            "PI_CODING_AGENT_SESSION_DIR": sessionDirectory.path,
            "APPLE_PI_DATA_ROOT": dataRoot.path,
        ]
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-ApplePiAppearance", appearance,
            "-ApplePiCompletedSetup", skipOnboarding ? "YES" : "NO",
            "-ApplePiSkipOnboarding", skipOnboarding ? "YES" : "NO",
            "-ApplePiSavedExecutablePath", "/nonexistent/applepi-ui-test-pi",
            "-ApplePiSidebarOrganization", "byProject",
            "-ApplePiSidebarTaskSortOrder", "priority",
        ]
        if skipOnboarding {
            app.launchArguments.append("--skip-onboarding")
        }
        didLaunchApplication = true
        app.launch()
        return app
    }

    private func seedTerminalSession(in directory: URL, workingDirectory: URL, title: String) {
        let records: [[String: Any]] = [
            [
                "type": "session",
                "version": 3,
                "id": "terminal-session",
                "timestamp": "2026-08-25T12:00:00.000Z",
                "cwd": workingDirectory.path,
            ],
            [
                "type": "message",
                "id": "terminal-message",
                "timestamp": "2026-08-25T12:00:01.000Z",
                "message": ["role": "user", "content": title],
            ],
        ]
        let lines = records.compactMap { record -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
        guard lines.count == records.count else { return }
        try? (lines.joined(separator: "\n") + "\n").write(
            to: directory.appending(path: "terminal-session.jsonl"),
            atomically: true,
            encoding: .utf8
        )
    }

    @MainActor
    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func interactiveProjectsHeaderElement(in app: XCUIApplication) -> XCUIElement {
        app.menuButtons
            .matching(NSPredicate(format: "identifier CONTAINS %@", "applepi.add-project"))
            .firstMatch
    }

    @MainActor
    private func projectsHeaderElement(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "applepi.projects-disclosure"))
            .firstMatch
    }

    @MainActor
    private func tasksHeaderElement(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "applepi.tasks-disclosure"))
            .firstMatch
    }

    @MainActor
    private func interactiveTasksHeaderElement(in app: XCUIApplication) -> XCUIElement {
        app.menuButtons
            .matching(NSPredicate(format: "identifier CONTAINS %@", "applepi.new-task"))
            .firstMatch
    }

    @MainActor
    private func draftRow(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND value == %@",
                "applepi.session-row.",
                "draft"
            ))
            .firstMatch
    }

    @MainActor
    private func movePointerAwayFromSidebar(in app: XCUIApplication) {
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
            .hover()
    }

    @MainActor
    private func clickAddTask(in app: XCUIApplication) {
        let hoverTarget = tasksHeaderElement(in: app)
        XCTAssertTrue(hoverTarget.waitForExistence(timeout: 10))
        guard hoverTarget.exists else { return }
        hoverTarget.hover()

        let tasksHeader = interactiveTasksHeaderElement(in: app)
        XCTAssertTrue(tasksHeader.waitForExistence(timeout: 10))
        guard tasksHeader.exists else { return }
        tasksHeader.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).click()
    }

    @MainActor
    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = ProcessInfo.processInfo.environment["APPLE_PI_CAPTURE_GOLDENS"] == "1"
            ? .keepAlways
            : .deleteOnSuccess
        add(attachment)
    }
}

private struct SeedProject: Codable {
    struct ID: Codable {
        let rawValue: UUID
    }

    let id: ID
    let name: String
    let workingDirectory: URL
    let isPinned: Bool
    let createdAt: Date
    let updatedAt: Date

    init(name: String, workingDirectory: URL) {
        id = ID(rawValue: UUID())
        self.name = name
        self.workingDirectory = workingDirectory
        isPinned = false
        createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        updatedAt = createdAt
    }
}
