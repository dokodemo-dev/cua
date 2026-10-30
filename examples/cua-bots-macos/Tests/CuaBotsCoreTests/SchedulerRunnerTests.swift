// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation
import Testing

@testable import CuaBotsCore

private actor Recorder {
  private(set) var prompts: [String] = []
  private(set) var keys: [String] = []
  func record(_ claim: DeliveryClaim) {
    prompts.append(claim.prompt)
    keys.append(claim.deliveryKey)
  }
  var count: Int { prompts.count }
}

private struct ScriptedExecutor: ScheduledWorkExecutor {
  enum Behavior: Sendable { case succeed, fail, hang }
  let recorder: Recorder
  let behavior: Behavior
  func execute(_ claim: DeliveryClaim) async throws {
    await recorder.record(claim)
    switch behavior {
    case .succeed: return
    case .fail: throw CancellationError()
    case .hang:
      try await Task.sleep(for: .seconds(30))
    }
  }
}

struct SchedulerRunnerTests {
  private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  private let key = "job"
  private let prompt = "Summarize the inbox"

  private func state(owner: String = "svc-a") throws -> (SchedulerState, UUID) {
    var state = SchedulerState(ownerID: owner)
    let job = try state.addJob(
      botID: "alpha", title: "Digest", prompt: prompt, cadence: 3600, startAt: t0)
    return (state, job)
  }

  @Test func aDeliveredSlotRunsOnceAndIsNotRepeated() async throws {
    let recorder = Recorder()
    var (state, _) = try state()
    var clock = t0.addingTimeInterval(1)
    var runner = ScheduledDeliveryRunner(
      state: state, executor: ScriptedExecutor(recorder: recorder, behavior: .succeed),
      timeout: 5, now: { clock })
    let first = await runner.runDue(limit: 4)
    #expect(first.count == 1)
    #expect(first.first?.delivered == true)
    let second = await runner.runDue(limit: 4)
    #expect(second.isEmpty)
    #expect(await recorder.count == 1)
    #expect(await recorder.prompts == [prompt])
    state = runner.state
    #expect(state.delivery(first[0].claim.deliveryKey)?.state == .delivered)
    clock = clock.addingTimeInterval(1)
  }

  @Test func aFailureIsRecordedAndOnlyAnExplicitResendRunsAgain() async throws {
    let recorder = Recorder()
    var (state, _) = try state()
    var clock = t0.addingTimeInterval(1)
    var runner = ScheduledDeliveryRunner(
      state: state, executor: ScriptedExecutor(recorder: recorder, behavior: .fail), timeout: 5,
      now: { clock })
    let outcomes = await runner.runDue(limit: 4)
    #expect(outcomes.first?.delivered == false)
    let failedKey = outcomes[0].claim.deliveryKey
    #expect(runner.state.delivery(failedKey)?.state == .failed)
    #expect(runner.state.failedDeliveries().count == 1)

    // Nothing is retried on the next tick.
    clock = clock.addingTimeInterval(1)
    let retryTick = await runner.runDue(limit: 4)
    #expect(retryTick.isEmpty)
    #expect(await recorder.count == 1)

    // A human resend is the only way back, and it happens exactly once.
    try runner.state.acknowledgeUnconfirmed(failedKey, resend: true, at: clock)
    clock = clock.addingTimeInterval(1)
    let resent = await runner.runDue(limit: 4)
    #expect(resent.count == 1)
    #expect(resent[0].claim.attempt == 2)
    #expect(await recorder.count == 2)
    clock = clock.addingTimeInterval(1)
    #expect(await runner.runDue(limit: 4).isEmpty)
  }

  @Test func aHangingExecutorIsCutOffAndRecordedAsFailed() async throws {
    let recorder = Recorder()
    let (state, _) = try state()
    let clock = t0.addingTimeInterval(1)
    var runner = ScheduledDeliveryRunner(
      state: state, executor: ScriptedExecutor(recorder: recorder, behavior: .hang), timeout: 0.2,
      now: { clock })
    let started = Date()
    let outcomes = await runner.runDue(limit: 1)
    let elapsed = Date().timeIntervalSince(started)
    #expect(elapsed < 5)
    #expect(outcomes.first?.delivered == false)
    #expect(outcomes.first?.error?.contains("timedOut") == true)
    #expect(runner.state.failedDeliveries().count == 1)
  }

  @Test func aRunnerWithoutTheLeaseExecutesNothing() async throws {
    let recorder = Recorder()
    let (seed, _) = try state(owner: "svc-a")
    var holder = seed
    #expect(try holder.acquireLease(now: t0, duration: 600))
    // A second process reads the same file while the first still holds the lease.
    var contender = SchedulerState(state: holder)
    contender.ownerID = "svc-b"
    var runner = ScheduledDeliveryRunner(
      state: contender, executor: ScriptedExecutor(recorder: recorder, behavior: .succeed),
      timeout: 5, now: { self.t0.addingTimeInterval(1) })
    let outcomes = await runner.runDue(limit: 4)
    #expect(outcomes.isEmpty)
    #expect(await recorder.count == 0)
    #expect(runner.state.lease?.owner == "svc-a")
  }
}

@MainActor
struct EngineScheduledExecutorTests {
  private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  private func claim(botID: String, prompt: String) -> DeliveryClaim {
    DeliveryClaim(
      jobID: UUID(), botID: botID, title: "Digest", prompt: prompt,
      scheduledAt: t0, deliveryKey: "k-\(prompt)", attempt: 1)
  }

  @Test func theFirstDeliveryStartsTheRunAndLaterOnesSend() async throws {
    let engine = ScriptedEngine()
    engine.replies = ["one", "two"]
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let volume = LocalVolume(root: root)
    var bot = Bot(name: "alpha")
    var runID: String?
    let executor = EngineScheduledExecutor(engine: engine, volume: volume) { _ in
      var copy = bot
      copy.runID = runID
      return copy
    }
    try await executor.execute(claim(botID: bot.id, prompt: "First"))
    #expect(engine.starts.count == 1)
    #expect(engine.sent == ["First"])
    runID = "run-1"
    bot.runID = runID
    try await executor.execute(claim(botID: bot.id, prompt: "Second"))
    #expect(engine.starts.count == 1)
    #expect(engine.sent == ["First", "Second"])
  }

  @Test func aPausedOrUnknownBotIsRefusedSoTheSlotFails() async throws {
    let engine = ScriptedEngine()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var bot = Bot(name: "alpha")
    bot.isPaused = true
    let executor = EngineScheduledExecutor(
      engine: engine, volume: LocalVolume(root: root)
    ) { id in id == bot.id ? bot : nil }
    await #expect(throws: ScheduledExecutorError.paused(bot.id)) {
      try await executor.execute(claim(botID: bot.id, prompt: "Ping"))
    }
    await #expect(throws: ScheduledExecutorError.unknownBot("ghost")) {
      try await executor.execute(claim(botID: "ghost", prompt: "Ping"))
    }
    #expect(engine.starts.isEmpty)
    #expect(engine.sent.isEmpty)
  }
}
