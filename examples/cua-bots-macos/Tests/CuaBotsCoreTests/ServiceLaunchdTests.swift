// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation
import Testing

@testable import CuaBotsCore

struct ServiceLaunchdTests {
  @Test func theRenderedPlistParsesAndCarriesTheJobSettings() throws {
    let job = ServiceLaunchd.Job(
      label: "ai.cua.bots.service", program: "/tmp/cua-bots-service",
      arguments: ["--state", "/tmp/state & logs"], stateDirectory: "/tmp/state & logs")
    let xml = try ServiceLaunchd.propertyList(job)
    #expect(xml.contains("<key>KeepAlive</key>"))
    #expect(xml.contains("&amp;"))
    #expect(!xml.contains("/tmp/state & logs"))
    let data = try #require(xml.data(using: .utf8))
    let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
    let dictionary = try #require(parsed as? [String: Any])
    #expect(dictionary["Label"] as? String == "ai.cua.bots.service")
    let programArguments = try #require(dictionary["ProgramArguments"] as? [String])
    #expect(programArguments == ["/tmp/cua-bots-service", "--state", "/tmp/state & logs"])
    #expect(dictionary["RunAtLoad"] as? Bool == true)
    #expect(dictionary["ThrottleInterval"] as? Int == 10)
    #expect(dictionary["StandardOutPath"] as? String == "/tmp/state & logs/launchd.out.log")
  }

  @Test func invalidJobsAreRejected() {
    let base = ServiceLaunchd.Job(
      label: "ok", program: "/bin/sh", stateDirectory: "/tmp")
    var emptyLabel = base
    emptyLabel.label = "not a label!"
    #expect(throws: ServiceLaunchd.ManifestError.emptyLabel) {
      _ = try ServiceLaunchd.propertyList(emptyLabel)
    }
    var relative = base
    relative.program = "bin/sh"
    #expect(throws: ServiceLaunchd.ManifestError.relativeProgram) {
      _ = try ServiceLaunchd.propertyList(relative)
    }
    var negative = base
    negative.throttleInterval = -1
    #expect(throws: ServiceLaunchd.ManifestError.invalidThrottle) {
      _ = try ServiceLaunchd.propertyList(negative)
    }
  }

  @Test func thePlistNeverCarriesASecret() throws {
    let job = ServiceLaunchd.Job(
      label: "ai.cua.bots.scheduler", program: "/tmp/cua-bots-scheduler",
      arguments: ["--state", "/tmp/state", "--owner", "svc-a"], stateDirectory: "/tmp/state")
    let xml = try ServiceLaunchd.propertyList(job)
    #expect(!xml.lowercased().contains("token"))
    #expect(!xml.contains("Bearer"))
  }
}
