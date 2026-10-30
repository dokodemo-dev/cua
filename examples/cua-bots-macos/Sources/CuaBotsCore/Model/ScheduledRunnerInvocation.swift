// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation

/// What the scheduler hands to a runner process through its environment. The
/// runner rebuilds the claim from these values so the slot key stays identical
/// on both sides.
public struct ScheduledRunnerInvocation: Equatable, Sendable {
  public var botID: String
  public var prompt: String
  public var title: String
  public var deliveryKey: String
  public var attempt: Int

  public init(
    botID: String, prompt: String, title: String, deliveryKey: String, attempt: Int = 1
  ) {
    self.botID = botID
    self.prompt = prompt
    self.title = title
    self.deliveryKey = deliveryKey
    self.attempt = attempt
  }

  public enum EnvironmentError: Error, Equatable {
    case missing(String)
    case invalidAttempt(String)
    case invalidKey(String)
  }

  public static let botKey = "CUA_BOTS_BOT_ID"
  public static let promptKey = "CUA_BOTS_PROMPT"
  public static let titleKey = "CUA_BOTS_TITLE"
  public static let deliveryKeyKey = "CUA_BOTS_DELIVERY_KEY"
  public static let attemptKey = "CUA_BOTS_ATTEMPT"

  public static func fromEnvironment(_ environment: [String: String]) throws
    -> ScheduledRunnerInvocation
  {
    func value(_ key: String) throws -> String {
      guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
        !raw.isEmpty
      else { throw EnvironmentError.missing(key) }
      return raw
    }
    let attemptText = environment[attemptKey] ?? "1"
    guard let attempt = Int(attemptText), attempt >= 1 else {
      throw EnvironmentError.invalidAttempt(attemptText)
    }
    let key = try value(deliveryKeyKey)
    guard !key.contains("\n"), !key.contains("\r") else {
      throw EnvironmentError.invalidKey(key)
    }
    return ScheduledRunnerInvocation(
      botID: try value(botKey), prompt: try value(promptKey), title: try value(titleKey),
      deliveryKey: key, attempt: attempt)
  }

  public var claim: DeliveryClaim {
    DeliveryClaim(
      jobID: UUID(), botID: botID, title: title, prompt: prompt, scheduledAt: Date(),
      deliveryKey: deliveryKey, attempt: attempt)
  }

  /// Start the Bot's run the first time, send a new turn afterwards.
  public enum Decision: Equatable, Sendable {
    case start, send
    case refused(String)
  }

  public static func decide(bot: Bot?) -> Decision {
    guard let bot else { return .refused("unknown Bot") }
    guard !bot.isPaused else { return .refused("paused") }
    return bot.runID == nil ? .start : .send
  }
}
