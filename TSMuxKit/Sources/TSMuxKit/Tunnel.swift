import Foundation

/// One call into the Go core's API (`mobile/main.go`). On iOS the app sends it
/// to the packet tunnel extension, which passes the bytes to `TSMuxCall` as is.
public struct TunnelRequest: Codable, Sendable, Equatable {
  public let method: String
  public let path: String
  /// JSON text; the Go side decodes it per route.
  public let body: String?

  public init(method: String, path: String, body: String? = nil) {
    self.method = method
    self.path = path
    self.body = body
  }

  public static let status = TunnelRequest(method: "GET", path: "/status")
  public static let pac = TunnelRequest(method: "GET", path: "/proxy.pac")

  public static func prefs(_ p: PrefsChange) throws -> TunnelRequest {
    TunnelRequest(method: "POST", path: "/prefs", body: try json(p))
  }

  public static func logout(_ profile: String) throws -> TunnelRequest {
    TunnelRequest(method: "POST", path: "/logout", body: try json(PrefsChange(profile: profile)))
  }

  public static func addProfile(name: String, displayName: String, controlURL: String) throws
    -> TunnelRequest
  {
    TunnelRequest(
      method: "POST", path: "/profiles/add",
      body: try json(ProfileEdit(name: name, displayName: displayName, controlURL: controlURL)))
  }

  /// Renames a tailnet once sign-in has said what it is. `newName` moves the
  /// config key and the saved login with it.
  public static func renameProfile(_ name: String, to newName: String, displayName: String) throws
    -> TunnelRequest
  {
    TunnelRequest(
      method: "POST", path: "/profiles/rename",
      body: try json(ProfileEdit(name: name, displayName: displayName, newName: newName)))
  }

  public static func removeProfile(_ name: String) throws -> TunnelRequest {
    TunnelRequest(method: "POST", path: "/profiles/remove", body: try json(ProfileEdit(name: name)))
  }
}

/// The response `TSMuxCall` returns: an HTTP status and the handler's body.
public struct TunnelResponse: Codable, Sendable {
  public let code: Int
  public let body: String

  public init(code: Int, body: String) {
    self.code = code
    self.body = body
  }

  /// Decodes a 2xx body, or throws the `{"error": …}` the API sends otherwise.
  public func decode<T: Decodable>(_: T.Type) throws -> T {
    let data = Data(body.utf8)
    guard (200..<300).contains(code) else {
      let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
      throw TunnelError(message: msg ?? body.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return try JSONDecoder().decode(T.self, from: data)
  }
}

public struct TunnelError: Error, Sendable, Equatable, LocalizedError {
  public let message: String
  public init(message: String) { self.message = message }
  public var errorDescription: String? { message }
}

/// POST /prefs: a nil field is left alone.
public struct PrefsChange: Codable, Sendable, Equatable {
  public var profile: String
  public var connected: Bool?
  public var acceptRoutes: Bool?
  public var acceptDNS: Bool?
  public var shieldsUp: Bool?
  public var exitNode: String?
  public var exitNodeAllowLAN: Bool?

  public init(profile: String) { self.profile = profile }

  enum CodingKeys: String, CodingKey {
    case profile, connected
    case acceptRoutes = "accept_routes"
    case acceptDNS = "accept_dns"
    case shieldsUp = "shields_up"
    case exitNode = "exit_node"
    case exitNodeAllowLAN = "exit_node_allow_lan"
  }
}

struct ProfileEdit: Codable, Sendable {
  var name: String
  var displayName: String?
  var controlURL: String?
  var newName: String?

  enum CodingKeys: String, CodingKey {
    case name
    case displayName = "display_name"
    case controlURL = "control_url"
    case newName = "new_name"
  }
}

private func json(_ value: some Encodable) throws -> String {
  String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

/// The container the app and the tunnel extension share: the Go core keeps
/// config.yaml, the tailnets' state and its log there.
public let appGroupID = "group.dev.northisup.tsmux"
