import Foundation
import Testing

@testable import TSMuxKit

@Suite struct StateDirectoryTests {
  @Test func excludesStateFromBackupAndClosesPermissions() throws {
    let container = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: container) }

    let dir = try prepareStateDirectory(in: container)
    #expect(dir.lastPathComponent == "state")
    let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
    let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.int16Value == 0o700)
  }

  @Test func isIdempotent() throws {
    let container = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: container) }

    let first = try prepareStateDirectory(in: container)
    try Data("{}".utf8).write(to: first.appending(path: "keep"))
    let second = try prepareStateDirectory(in: container)
    #expect(first == second)
    #expect(FileManager.default.fileExists(atPath: second.appending(path: "keep").path))
  }
}
