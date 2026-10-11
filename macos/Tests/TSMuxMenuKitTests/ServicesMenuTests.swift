import AppKit
import Foundation
import TSMuxKit
import Testing

@testable import TSMuxMenuKit

@MainActor struct ServicesMenuTests {
  private func profile(_ services: String) throws -> ProfileStatus {
    let json =
      #"{"profile":"home","display_name":"Home","state":"Running","services":\#(services)}"#
    return try JSONDecoder().decode(ProfileStatus.self, from: Data(json.utf8))
  }

  @Test func hiddenWithoutServices() throws {
    #expect(Controller.servicesItem(try profile("[]"), target: nil) == nil)
    #expect(Controller.servicesItem(try profile("null"), target: nil) == nil)
  }

  @Test func rowsCopyNameAndIPAndToggleRouting() throws {
    let p = try profile(
      #"""
      [{"name":"svc:romm","dns_name":"romm.example.ts.net","ips":["100.90.45.67"],"routed":true},
       {"name":"svc:wiki","dns_name":"wiki.example.ts.net","ips":["100.90.1.2"],"routed_by":"work"}]
      """#)
    let root = try #require(Controller.servicesItem(p, target: nil))
    #expect(root.title == "Services (2)")
    let items = try #require(root.submenu?.items)
    let romm = Array(items[0..<3])
    #expect(
      romm.map { $0.representedObject as? String } == ["romm.example.ts.net", "100.90.45.67", nil])
    #expect(romm.map(\.keyEquivalentModifierMask) == [[], [.option], [.command]])
    #expect(romm.allSatisfy { $0.state == .on })
    let route = try #require(romm[2].representedObject as? Controller.RouteIP)
    #expect(route.target == "svc:romm" && route.on == false)

    let wiki = Array(items[3..<6])
    #expect(wiki.allSatisfy { $0.state == .off })
    #expect(wiki[2].isEnabled == false)
    #expect(wiki[2].attributedTitle?.string.contains("routed to work") == true)
  }
}
