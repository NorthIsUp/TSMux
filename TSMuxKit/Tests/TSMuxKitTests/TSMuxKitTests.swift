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

  @Test func groupsPeopleBeforeTagsOnlineFirst() throws {
    let groups = deviceGroups(try #require(try fixture().first?.devices))
    #expect(groups.map(\.name) == ["user@example.com", "tag:server"])
    #expect(groups[0].devices.map(\.shortName) == ["laptop", "phone"])
  }

  @Test func errorBodiesThrowTheirMessage() {
    let r = TunnelResponse(code: 400, body: #"{"error":"no profile \"x\""}"#)
    #expect(throws: TunnelError(message: #"no profile "x""#)) { try r.decode([ProfileStatus].self) }
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
