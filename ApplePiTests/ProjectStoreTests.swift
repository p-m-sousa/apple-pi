import Foundation
import Testing
@testable import ApplePi

@Suite("Saved project persistence")
struct ProjectStoreTests {
    @Test("Project Codable round trip preserves its stable identity and dates")
    func modelRoundTrip() throws {
        let id = ApplePiProjectID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedAt = createdAt.addingTimeInterval(60)
        let project = ApplePiProject(
            id: id,
            name: "Apple Pi",
            workingDirectory: URL(filePath: "/tmp/apple-pi", directoryHint: .isDirectory),
            isPinned: true,
            createdAt: createdAt,
            updatedAt: updatedAt
        )

        let encoded = try JSONEncoder.applePi.encode(project)
        let decoded = try JSONDecoder.applePi.decode(ApplePiProject.self, from: encoded)

        #expect(decoded == project)
        #expect(decoded.id == id)
        #expect(decoded.isPinned)
        #expect(decoded.createdAt == createdAt)
        #expect(decoded.updatedAt == updatedAt)
    }

    @Test("Projects saved before pinning was added decode as unpinned")
    func legacyProjectWithoutPinDecodes() throws {
        let project = ApplePiProject(
            name: "Legacy",
            workingDirectory: URL(filePath: "/tmp/legacy-project", directoryHint: .isDirectory)
        )
        let encoded = try JSONEncoder.applePi.encode(project)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "isPinned")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder.applePi.decode(ApplePiProject.self, from: legacyData)

        #expect(!decoded.isPinned)
    }

    @Test("A missing persistence file starts with an empty explicit project list")
    func missingFileStartsEmpty() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "support/projects.json")
        let store = ProjectStore(fileURL: fileURL)

        #expect(await store.allProjects().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("Create, read, update, and delete persist atomically across store instances")
    func CRUDPersists() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "support/projects.json")
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = firstDate.addingTimeInterval(120)
        let clock = TestClock([firstDate, secondDate])
        let store = ProjectStore(fileURL: fileURL, now: { clock.next() })
        let originalDirectory = directory.appending(path: "original", directoryHint: .isDirectory)
        let renamedDirectory = directory.appending(path: "renamed", directoryHint: .isDirectory)

        let created = try await store.create(
            name: "  Original Project  ",
            workingDirectory: originalDirectory
        )
        #expect(created.name == "Original Project")
        #expect(created.createdAt == firstDate)
        #expect(created.updatedAt == firstDate)
        #expect(await store.project(id: created.id) == created)
        #expect(await store.project(forWorkingDirectory: originalDirectory) == created)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let reloaded = ProjectStore(fileURL: fileURL)
        #expect(await reloaded.allProjects() == [created])

        let updated = try await store.update(
            id: created.id,
            name: "Renamed Project",
            workingDirectory: renamedDirectory,
            isPinned: true
        )
        #expect(updated.id == created.id)
        #expect(updated.createdAt == created.createdAt)
        #expect(updated.updatedAt == secondDate)
        #expect(updated.name == "Renamed Project")
        #expect(updated.isPinned)
        #expect(updated.workingDirectory == renamedDirectory.standardizedFileURL)
        #expect(await store.project(forWorkingDirectory: originalDirectory) == nil)
        #expect(await store.project(forWorkingDirectory: renamedDirectory)?.id == created.id)

        let afterUpdate = ProjectStore(fileURL: fileURL)
        #expect(await afterUpdate.allProjects() == [updated])

        let removed = try await store.delete(id: created.id)
        #expect(removed == updated)
        #expect(await store.allProjects().isEmpty)
        #expect(await ProjectStore(fileURL: fileURL).allProjects().isEmpty)
    }

    @Test("Project directories are unique without implying task membership")
    func directoryUniqueness() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "projects.json")
        let projectDirectory = directory.appending(path: "workspace", directoryHint: .isDirectory)
        let store = ProjectStore(fileURL: fileURL)
        let first = try await store.create(name: "First", workingDirectory: projectDirectory)

        await #expect(throws: ProjectStoreError.self) {
            try await store.create(
                name: "Duplicate",
                workingDirectory: projectDirectory.appending(path: "..", directoryHint: .isDirectory)
                    .appending(path: "workspace", directoryHint: .isDirectory)
            )
        }
        #expect(await store.allProjects() == [first])
    }

    @Test("Project directory matching includes descendants and prefers the closest root")
    func projectDirectoryMatching() {
        let parent = ApplePiProject(
            name: "Parent",
            workingDirectory: URL(filePath: "/tmp/workspace", directoryHint: .isDirectory)
        )
        let nested = ApplePiProject(
            name: "Nested",
            workingDirectory: URL(filePath: "/tmp/workspace/packages/app", directoryHint: .isDirectory)
        )

        #expect(ProjectDirectoryMatcher.bestMatch(
            for: URL(filePath: "/tmp/workspace", directoryHint: .isDirectory),
            among: [parent, nested]
        )?.id == parent.id)
        #expect(ProjectDirectoryMatcher.bestMatch(
            for: URL(filePath: "/tmp/workspace/packages/app/Sources", directoryHint: .isDirectory),
            among: [parent, nested]
        )?.id == nested.id)
        #expect(ProjectDirectoryMatcher.bestMatch(
            for: URL(filePath: "/tmp/workspace-copy", directoryHint: .isDirectory),
            among: [parent, nested]
        ) == nil)
    }

    @Test("A legacy unversioned project array is migrated to the versioned envelope")
    func legacyArrayMigration() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "projects.json")
        let project = ApplePiProject(
            name: "Legacy",
            workingDirectory: directory.appending(path: "legacy", directoryHint: .isDirectory),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try JSONEncoder.applePi.encode([project]).write(to: fileURL, options: .atomic)

        let store = ProjectStore(fileURL: fileURL)
        #expect(await store.allProjects() == [project])

        let migrated = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        #expect(migrated["version"] as? Int == 1)
        #expect((migrated["projects"] as? [Any])?.count == 1)
    }

    @Test("Failed validation leaves in-memory and persisted projects unchanged")
    func validationIsTransactional() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "projects.json")
        let store = ProjectStore(fileURL: fileURL)
        let project = try await store.create(name: "Valid", workingDirectory: directory)

        await #expect(throws: ProjectStoreError.emptyName) {
            try await store.update(id: project.id, name: " \n ")
        }
        await #expect(throws: ProjectStoreError.self) {
            try await store.delete(id: ApplePiProjectID())
        }

        #expect(await store.allProjects() == [project])
        let persisted = await ProjectStore(fileURL: fileURL).allProjects()
        #expect(persisted.count == 1)
        #expect(persisted.first?.id == project.id)
        #expect(persisted.first?.name == project.name)
        #expect(persisted.first?.workingDirectory.standardizedFileURL.path
            == project.workingDirectory.standardizedFileURL.path)
        #expect(abs((persisted.first?.createdAt ?? .distantPast).timeIntervalSince(project.createdAt)) < 1)
        #expect(abs((persisted.first?.updatedAt ?? .distantPast).timeIntervalSince(project.updatedAt)) < 1)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]

    init(_ dates: [Date]) {
        self.dates = dates
    }

    func next() -> Date {
        lock.withLock {
            dates.removeFirst()
        }
    }
}
