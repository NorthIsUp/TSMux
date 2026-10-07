import Foundation
import Observation
import TSMuxSSH

/// What to connect to. Field names match shellcore's JSON.
public struct SSHRequest: Codable, Sendable, Equatable {
  public var socksAddr: String
  public var host: String
  public var port: Int?
  public var user: String
  public var hostKeys: [String]
  public var trustedKey: String?
  public var password: String?
  public var privateKey: String?
  public var cols: Int
  public var rows: Int

  public init(
    socksAddr: String, host: String, port: Int? = nil, user: String, hostKeys: [String] = [],
    trustedKey: String? = nil, password: String? = nil, privateKey: String? = nil,
    cols: Int = 80, rows: Int = 24
  ) {
    self.socksAddr = socksAddr
    self.host = host
    self.port = port
    self.user = user
    self.hostKeys = hostKeys
    self.trustedKey = trustedKey
    self.password = password
    self.privateKey = privateKey
    self.cols = cols
    self.rows = rows
  }

  enum CodingKeys: String, CodingKey {
    case socksAddr = "socks_addr"
    case host, port, user
    case hostKeys = "host_keys"
    case trustedKey = "trusted_key"
    case password
    case privateKey = "private_key"
    case cols, rows
  }
}

/// shellcore's view of one connection.
public struct SSHState: Decodable, Sendable, Equatable {
  public enum Phase: String, Decodable, Sendable {
    case connecting, open, failed, closed
  }

  public var phase: Phase
  public var error: String?
  public var errorKind: String?
  public var hostKey: String?
  public var fingerprint: String?
  public var urls: [String]?

  public static let idle = SSHState(phase: .connecting)

  public init(phase: Phase) { self.phase = phase }

  /// No pinned or remembered key vouches for the host; the user decides.
  public var isUnknownHostKey: Bool { errorKind == "unknown_host_key" }
  /// The host presented a different key than it is known by.
  public var isHostKeyMismatch: Bool { errorKind == "host_key_mismatch" }
  /// The tailnet's SSH policy doesn't let this user in.
  public var isDenied: Bool { errorKind == "denied" }

  enum CodingKeys: String, CodingKey {
    case phase, error
    case errorKind = "error_kind"
    case hostKey = "host_key"
    case fingerprint, urls
  }
}

/// One SSH shell over the Go client. Output arrives on the main actor through
/// the handler given to `start`; a background thread does the blocking reads.
@Observable @MainActor
public final class SSHConnection {
  public private(set) var state = SSHState.idle
  public private(set) var request: SSHRequest

  private var handle: Int64 = 0
  private var poller: Task<Void, Never>?
  private var size: (cols: Int, rows: Int)?
  private let writes = DispatchQueue(label: "TSMuxShell.writes")

  public init(_ request: SSHRequest) { self.request = request }

  /// Connects, replacing any earlier session. `output` gets the terminal's
  /// bytes in order.
  public func start(output: @escaping @MainActor ([UInt8]) -> Void) {
    close()
    if let size {
      request.cols = size.cols
      request.rows = size.rows
    }
    guard let json = try? String(decoding: JSONEncoder().encode(request), as: UTF8.self) else {
      return
    }
    let h = Int64(json.withCString { TSMuxSSHOpen(UnsafeMutablePointer(mutating: $0)) })
    guard h > 0 else {
      state = SSHState(phase: .failed)
      state.error = "The connection request was malformed."
      return
    }
    handle = h
    state = .idle
    Thread.detachNewThread {
      Self.readLoop(handle: h) { bytes in
        Task { @MainActor in output(bytes) }
      }
    }
    poller = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, self.handle == h else { return }
        let fresh = Self.readState(h)
        if fresh.phase == .open, self.state.phase != .open, let size = self.size {
          TSMuxSSHResize(h, Int32(size.cols), Int32(size.rows))
        }
        self.state = fresh
        if fresh.phase == .failed || fresh.phase == .closed { return }
        try? await Task.sleep(for: .milliseconds(fresh.phase == .open ? 1000 : 250))
      }
    }
  }

  public func send(_ bytes: [UInt8]) {
    let h = handle
    guard h > 0, !bytes.isEmpty else { return }
    writes.async {
      bytes.withUnsafeBufferPointer { p in
        p.baseAddress.map { base in
          _ = TSMuxSSHWrite(
            h,
            UnsafeMutablePointer(
              mutating: UnsafeRawPointer(base).assumingMemoryBound(to: CChar.self)),
            Int32(p.count))
        }
      }
    }
  }

  public func resize(cols: Int, rows: Int) {
    guard cols > 0, rows > 0 else { return }
    size = (cols, rows)
    if handle > 0, state.phase == .open { TSMuxSSHResize(handle, Int32(cols), Int32(rows)) }
  }

  public func close() {
    poller?.cancel()
    poller = nil
    if handle > 0 { TSMuxSSHClose(handle) }
    handle = 0
    if state.phase == .open || state.phase == .connecting { state = SSHState(phase: .closed) }
  }

  nonisolated private static func readState(_ h: Int64) -> SSHState {
    guard let raw = TSMuxSSHState(h) else { return SSHState(phase: .closed) }
    defer { TSMuxSSHFree(raw) }
    return (try? JSONDecoder().decode(SSHState.self, from: Data(String(cString: raw).utf8)))
      ?? SSHState(phase: .closed)
  }

  nonisolated private static func readLoop(
    handle: Int64, deliver: @escaping @Sendable ([UInt8]) -> Void
  ) {
    var buf = [UInt8](repeating: 0, count: 32 * 1024)
    while true {
      let n = buf.withUnsafeMutableBytes { raw in
        TSMuxSSHRead(handle, raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count))
      }
      if n < 0 { return }
      deliver(Array(buf[0..<Int(n)]))
    }
  }
}
