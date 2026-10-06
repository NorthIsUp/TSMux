import Foundation

/// Creates the Go core's state dir in the App Group container and locks it
/// down before `TSMuxStart` writes node private keys into it: out of device
/// and iCloud backups, and encrypted until the first unlock after boot.
/// Files the core creates later inherit the directory's protection class.
@discardableResult
public func prepareStateDirectory(in container: URL) throws -> URL {
  // mobile/main.go's load() sets Paths.StateDir to this path.
  var dir = container.appending(path: "state", directoryHint: .isDirectory)
  let fm = FileManager.default
  try fm.createDirectory(
    at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  var values = URLResourceValues()
  values.isExcludedFromBackup = true
  try dir.setResourceValues(values)
  #if os(iOS)
    // Not .complete: on-demand reconnects start the tunnel while the device
    // is locked, and the core must read its keys then.
    let protection: [FileAttributeKey: Any] = [
      .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
    ]
    try fm.setAttributes(protection, ofItemAtPath: dir.path)
    // Files from before this existed keep whatever class they were made with.
    if let existing = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
      for case let url as URL in existing {
        try fm.setAttributes(protection, ofItemAtPath: url.path)
      }
    }
  #endif
  return dir
}
