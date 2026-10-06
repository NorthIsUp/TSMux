import Foundation
import Testing

@testable import TSMuxKit

@Suite struct WireTests {
  func fixture() throws -> [ProfileStatus] {
    let url = try #require(Bundle.module.url(forResource: "status", withExtension: "json"))
    return try JSONDecoder().decode([ProfileStatus].self, from: Data(contentsOf: url))
  }

  @Test func decodesDaemonStatus() throws {
    let s = try #require(try fixture().first)
    #expect(s.condition == .running)
    #expect(s.machineName == "tsmux-home.example.ts.net")
    #expect(s.devices?.count == 3)
  }

  @Test func deviceApprovalIsItsOwnCondition() throws {
    let json = #"{"profile":"work","display_name":"Work","state":"NeedsMachineAuth"}"#
    let s = try JSONDecoder().decode(ProfileStatus.self, from: Data(json.utf8))
    #expect(s.condition == .needsApproval)
  }

  private func lockStatus(state: String = "Running", lock: String) throws -> ProfileStatus {
    let json =
      #"{"profile":"work","display_name":"Work","state":"\#(state)","tailnet_lock":\#(lock)}"#
    return try JSONDecoder().decode(ProfileStatus.self, from: Data(json.utf8))
  }

  @Test func decodesTailnetLock() throws {
    let s = try lockStatus(
      lock: #"""
        {"enabled":true,"signed":false,"locked_out":true,"node_key":"nodekey:ab",
         "public_key":"tlpub:cd","sign_command":"tailscale lock sign nodekey:ab tlpub:cd"}
        """#)
    let tl = try #require(s.tailnetLock)
    #expect(tl.enabled && !tl.signed && tl.lockedOut)
    #expect(tl.nodeKey == "nodekey:ab")
    #expect(tl.publicKey == "tlpub:cd")
    #expect(tl.signCommand == "tailscale lock sign nodekey:ab tlpub:cd")
  }

  @Test func absentTailnetLockDecodesAsNil() throws {
    #expect(try fixture().first?.tailnetLock == nil)
  }

  @Test(arguments: [
    (
      "Running", #"{"enabled":true,"signed":false,"locked_out":true}"#,
      ProfileStatus.Condition.lockedOut, true
    ),
    ("Running", #"{"enabled":true,"signed":true,"locked_out":false}"#, .running, true),
    ("Running", #"{"enabled":false,"signed":false,"locked_out":false}"#, .running, true),
    ("Stopped", #"{"enabled":true,"signed":false,"locked_out":true}"#, .stopped, false),
  ])
  func lockedOutIsNotConnected(
    state: String, lock: String, want: ProfileStatus.Condition, up: Bool
  ) throws {
    let s = try lockStatus(state: state, lock: lock)
    #expect(s.condition == want)
    #expect(s.isUp == up)
  }

  @Test func onlyRunningAndLockedOutAreUp() {
    let up = ProfileStatus.Condition.allCases.filter(\.isUp)
    #expect(Set(up) == [.running, .lockedOut])
  }

  @Test func groupsPeopleBeforeTagsOnlineFirst() throws {
    let groups = deviceGroups(try #require(try fixture().first?.devices))
    #expect(groups.map(\.name) == ["user@example.com", "tag:server"])
    #expect(groups[0].devices.map(\.shortName) == ["laptop", "phone"])
  }

  // (this profile, its exit node pick, exit_profile, expected override)
  @Test(
    arguments: [
      ("home", "n1", "work", "Work"),
      ("work", "n2", "work", nil),
      ("home", "", "work", nil),
      ("home", "n1", "", nil),
    ] as [(String, String, String, String?)])
  func exitNodeOverride(profile: String, pick: String, winner: String, want: String?) throws {
    func status(_ name: String, _ display: String, _ exitNode: String) throws -> ProfileStatus {
      let json = """
        {"profile":"\(name)","display_name":"\(display)","state":"Running",
         "exit_profile":"\(winner)",
         "prefs":{"connected":true,"accept_routes":false,"accept_dns":true,
                  "shields_up":false,"exit_node":"\(exitNode)","exit_node_allow_lan":false}}
        """
      return try JSONDecoder().decode(ProfileStatus.self, from: Data(json.utf8))
    }
    let all = [
      try status("home", "Home", profile == "home" ? pick : ""),
      try status("work", "Work", profile == "work" ? pick : "n2"),
    ]
    let me = try #require(all.first { $0.profile == profile })
    #expect(me.exitNodeOverride(among: all) == want)
  }

  @Test func errorBodiesThrowTheirMessage() {
    let r = TunnelResponse(code: 400, body: #"{"error":"no profile \"x\""}"#)
    #expect(throws: TunnelError(message: #"no profile "x""#)) { try r.decode([ProfileStatus].self) }
  }

  @Test func removeCarriesLogoutWarning() throws {
    let warned = TunnelResponse(code: 200, body: #"{"ok":true,"warning":"could not log out"}"#)
    #expect(try warned.decode(ProfileEditResult.self).warning == "could not log out")
    let clean = TunnelResponse(code: 200, body: #"{"ok":true}"#)
    #expect(try clean.decode(ProfileEditResult.self) == ProfileEditResult(ok: true, warning: nil))
  }

  @Test func prefsBodyOmitsUnsetFields() throws {
    var p = PrefsChange(profile: "home")
    p.acceptRoutes = true
    let req = try TunnelRequest.prefs(p)
    let body =
      try JSONSerialization.jsonObject(with: Data(try #require(req.body).utf8)) as? [String: Any]
    #expect(body?.keys.sorted() == ["accept_routes", "profile"])
  }

  @Test func requestRoundTrips() throws {
    let req = try TunnelRequest.addProfile(name: "work", displayName: "Work", controlURL: "")
    let back = try JSONDecoder().decode(TunnelRequest.self, from: JSONEncoder().encode(req))
    #expect(back == req)
  }
}

@Suite struct SlugTests {
  @Test func keysFoldToAsciiDashes() {
    #expect(Slug.key("Café Work!") == "cafe-work")
    #expect(Slug.key("x") == "x-1")
    #expect(Slug.bump("work") == "work-2")
    #expect(Slug.bump("work-2") == "work-3")
  }

  @Test func suggestsNameFromSignIn() {
    #expect(Slug.suggestedName(tailnet: "askclara.com", magicDNSSuffix: nil) == "Askclara")
    #expect(Slug.suggestedName(tailnet: "adam@gmail.com", magicDNSSuffix: nil) == "Adam")
    #expect(Slug.suggestedName(tailnet: "", magicDNSSuffix: "tail1234.ts.net") == "Tail1234")
    #expect(Slug.suggestedName(tailnet: nil, magicDNSSuffix: nil) == "")
  }
}

@Suite struct AddFlowTests {
  private func status(_ state: String, extra: String = "") throws -> ProfileStatus {
    let json = #"{"profile":"new","display_name":"New tailnet","state":"\#(state)"\#(extra)}"#
    return try JSONDecoder().decode(ProfileStatus.self, from: Data(json.utf8))
  }

  @Test func walksSignInToNaming() throws {
    #expect(AddFlow.step(nil) == .connecting)
    #expect(AddFlow.step(try status("NeedsLogin")) == .waitingForLink)
    let link = try status("NeedsLogin", extra: #","auth_url":"https://login.example/a""#)
    #expect(AddFlow.step(link) == .signIn(URL(string: "https://login.example/a")!))
    #expect(AddFlow.step(try status("NeedsMachineAuth")) == .needsApproval(admin: nil))
    let up = try status("Running", extra: #","tailnet":"askclara.com""#)
    #expect(AddFlow.step(up) == .signedIn(suggestedName: "Askclara"))
    let locked = try status(
      "Running",
      extra:
        #","tailnet":"askclara.com","tailnet_lock":{"enabled":true,"signed":false,"locked_out":true}"#
    )
    #expect(AddFlow.step(locked) == .signedIn(suggestedName: "Askclara"))
  }

  @Test func opensEachLinkOnce() {
    var flow = AddFlow()
    let a = AddFlow.Step.signIn(URL(string: "https://login.example/a")!)
    let b = AddFlow.Step.signIn(URL(string: "https://login.example/b")!)
    #expect(!flow.signInStarted)
    #expect(flow.autoOpen(a) != nil)
    #expect(flow.autoOpen(a) == nil)
    #expect(flow.autoOpen(b) != nil)
    #expect(flow.signInStarted)
  }

  @Test func placeholderSkipsTakenKeys() {
    #expect(AddFlow.placeholderKey { _ in false } == "new")
    #expect(AddFlow.placeholderKey { ["new", "new-2"].contains($0) } == "new-3")
  }
}
