// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation

public enum ScheduledExecutorError: Error, Equatable {
  case unknownBot(String)
  case paused(String)
  case invalidClaim
}

/// Hands a claimed delivery to the real Bot engine: the first delivery starts
/// the run, later ones send a new turn. Errors are surfaced so the runner can
/// record the slot as failed instead of silently dropping it.
@MainActor
public final class EngineScheduledExecutor: ScheduledWorkExecutor {
  private let engine: BotEngine
  private let volume: VolumeStore
  private let botLookup: @MainActor (String) -> Bot?

  public init(
    engine: BotEngine, volume: VolumeStore, lookup: @MainActor @escaping (String) -> Bot?
  ) {
    self.engine = engine
    self.volume = volume
    self.botLookup = lookup
  }

  public nonisolated func execute(_ claim: DeliveryClaim) async throws {
    try await perform(claim)
  }

  @MainActor
  private func perform(_ claim: DeliveryClaim) async throws {
    guard !claim.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ScheduledExecutorError.invalidClaim
    }
    guard let target = botLookup(claim.botID) else {
      throw ScheduledExecutorError.unknownBot(claim.botID)
    }
    let bot = target
    guard !bot.isPaused else { throw ScheduledExecutorError.paused(bot.id) }
    if bot.runID == nil {
      _ = try await engine.start(bot, volume: volume, prompt: claim.prompt)
    } else {
      try await engine.push(bot, volume: volume)
      try await engine.send(bot, text: claim.prompt)
    }
  }
}
