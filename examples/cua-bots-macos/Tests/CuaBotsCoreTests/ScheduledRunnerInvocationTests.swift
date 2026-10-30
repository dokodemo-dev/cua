// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation
import Testing

@testable import CuaBotsCore

struct ScheduledRunnerInvocationTests {
  private func environment(attempt: String = "2") -> [String: String] {
    [
      ScheduledRunnerInvocation.botKey: "alpha",
      ScheduledRunnerInvocation.promptKey: "Summarize the inbox",
      ScheduledRunnerInvocation.titleKey: "Digest",
      ScheduledRunnerInvocation.deliveryKeyKey: "key-1",
      ScheduledRunnerInvocation.attemptKey: attempt,
    ]
  }

  @Test func theRunnerRebuildsTheSameSlotFromTheEnvironment() throws {
    let invocation = try ScheduledRunnerInvocation.fromEnvironment(environment())
    #expect(invocation.botID == "alpha")
    #expect(invocation.prompt == "Summarize the inbox")
    #expect(invocation.title == "Digest")
    #expect(invocation.deliveryKey == "key-1")
    #expect(invocation.attempt == 2)
    let claim = invocation.claim
    #expect(claim.deliveryKey == "key-1")
    #expect(claim.botID == "alpha")
    #expect(claim.prompt == "Summarize the inbox")
    #expect(claim.attempt == 2)
  }

  @Test func missingOrMalformedValuesAreRejected() {
    var missing = environment()
    missing.removeValue(forKey: ScheduledRunnerInvocation.promptKey)
    #expect(throws: ScheduledRunnerInvocation.EnvironmentError.missing("CUA_BOTS_PROMPT")) {
      _ = try ScheduledRunnerInvocation.fromEnvironment(missing)
    }
    #expect(
      throws: ScheduledRunnerInvocation.EnvironmentError.invalidAttempt("zero")
    ) {
      _ = try ScheduledRunnerInvocation.fromEnvironment(environment(attempt: "zero"))
    }
    var blank = environment()
    blank[ScheduledRunnerInvocation.botKey] = "   "
    #expect(throws: ScheduledRunnerInvocation.EnvironmentError.missing("CUA_BOTS_BOT_ID")) {
      _ = try ScheduledRunnerInvocation.fromEnvironment(blank)
    }
  }

  @Test func theDecisionFollowsTheBotsState() {
    var bot = Bot(name: "Alpha")
    #expect(ScheduledRunnerInvocation.decide(bot: nil) == .refused("unknown Bot"))
    #expect(ScheduledRunnerInvocation.decide(bot: bot) == .start)
    bot.runID = "run-1"
    #expect(ScheduledRunnerInvocation.decide(bot: bot) == .send)
    bot.isPaused = true
    #expect(ScheduledRunnerInvocation.decide(bot: bot) == .refused("paused"))
  }
}
