import CuaBotsCore
// SPDX-License-Identifier: FSL-1.1-MIT
// Headless schedule runner: proves the schedule works with the GUI closed.
// Claims happen under the file lock; execution happens outside it; the result is
// recorded under the lock again, so two processes can never send one slot twice.
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

private func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("error: \(message)\n".utf8))
  exit(2)
}

private struct Options {
  var stateDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
  var owner = "cua-bots-scheduler"
  var interval: TimeInterval = 1
  var leaseDuration: TimeInterval = 30
  var claimTimeout: TimeInterval = 120
  var limit = 4
  var execCommand: String?
  var execTimeout: TimeInterval = 600
  var crashAfterClaims: Int?
  var seed: (bot: String, title: String, prompt: String, cadence: TimeInterval)?
  var once = false
  var ticks: Int?
  var printLaunchdPlist = false
}

private func parse(_ arguments: [String]) -> Options {
  var options = Options()
  var index = 0
  while index < arguments.count {
    let flag = arguments[index]
    func value() -> String {
      guard index + 1 < arguments.count else { fail("\(flag) needs a value") }
      index += 1
      return arguments[index]
    }
    switch flag {
    case "--state": options.stateDirectory = URL(fileURLWithPath: value())
    case "--owner": options.owner = value()
    case "--interval": options.interval = TimeInterval(value()) ?? options.interval
    case "--lease": options.leaseDuration = TimeInterval(value()) ?? options.leaseDuration
    case "--claim-timeout": options.claimTimeout = TimeInterval(value()) ?? options.claimTimeout
    case "--limit": options.limit = Int(value()) ?? options.limit
    case "--exec-command": options.execCommand = value()
    case "--exec-timeout": options.execTimeout = TimeInterval(value()) ?? options.execTimeout
    case "--crash-after-claims": options.crashAfterClaims = Int(value())
    case "--seed-bot":
      let bot = value()
      let title = value()
      let prompt = value()
      options.seed = (bot, title, prompt, TimeInterval(value()) ?? 60)
    case "--print-launchd-plist": options.printLaunchdPlist = true
    case "--once": options.once = true
    case "--ticks": options.ticks = Int(value())
    default: fail("unknown flag \(flag)")
    }
    index += 1
  }
  return options
}

/// Runs one delivery as a shell command. Environment carries the prompt and the
/// slot key so the command can be idempotent on its own side too.
private struct CommandExecutor: ScheduledWorkExecutor {
  let command: String
  let timeout: TimeInterval

  func execute(_ claim: DeliveryClaim) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    var environment = ProcessInfo.processInfo.environment
    environment["CUA_BOTS_DELIVERY_KEY"] = claim.deliveryKey
    environment["CUA_BOTS_BOT_ID"] = claim.botID
    environment["CUA_BOTS_TITLE"] = claim.title
    environment["CUA_BOTS_PROMPT"] = claim.prompt
    environment["CUA_BOTS_ATTEMPT"] = String(claim.attempt)
    process.environment = environment
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
      try? await Task.sleep(for: .milliseconds(50))
    }
    if process.isRunning {
      process.terminate()
      throw CommandExecutionError.timedOut
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw CommandExecutionError.exit(process.terminationStatus)
    }
  }

  enum CommandExecutionError: Error, Equatable {
    case exit(Int32)
    case timedOut
  }
}

private struct RecordOnlyExecutor: ScheduledWorkExecutor {
  let url: URL
  func execute(_ claim: DeliveryClaim) async throws {
    let line =
      "\(claim.deliveryKey)\tattempt=\(claim.attempt)\tbot=\(claim.botID)\tprompt=\(claim.prompt)\n"
    let data = Data(line.utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: url)
    }
  }
}

private let options = parse(Array(CommandLine.arguments.dropFirst()))

func programPath() -> String {
  let raw = CommandLine.arguments.first ?? ""
  let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  return URL(fileURLWithPath: raw, relativeTo: base).standardized.path
}

if options.printLaunchdPlist {
  var arguments = ["--state", options.stateDirectory.path, "--owner", options.owner]
  if let command = options.execCommand {
    let timeoutValue =
      options.execTimeout == options.execTimeout.rounded()
      ? String(Int(options.execTimeout)) : String(options.execTimeout)
    arguments += ["--exec-command", command, "--exec-timeout", timeoutValue]
  }
  let job = ServiceLaunchd.Job(
    label: "ai.cua.bots.scheduler", program: programPath(), arguments: arguments,
    stateDirectory: options.stateDirectory.path)
  do {
    print(try ServiceLaunchd.propertyList(job), terminator: "")
    exit(0)
  } catch {
    fail("cannot render the launchd job: \(error)")
  }
}
private let stateURL = options.stateDirectory.appendingPathComponent("scheduler.json")
private let deliveryURL = options.stateDirectory.appendingPathComponent("delivered.log")
private let lockURL = options.stateDirectory.appendingPathComponent("scheduler.lock")
try? FileManager.default.createDirectory(
  at: options.stateDirectory, withIntermediateDirectories: true)

private let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
private let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.sortedKeys]

/// Atomic replace plus an exclusive file lock is the cross-process
/// serialization point: a second instance cannot read stale state and claim the
/// same slot.
private func withState<T>(_ body: (inout SchedulerState) throws -> T) -> T? {
  let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
  guard descriptor >= 0 else { fail("cannot open \(lockURL.path)") }
  defer {
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }
  guard flock(descriptor, LOCK_EX) == 0 else { fail("cannot lock \(lockURL.path)") }
  var state =
    (try? Data(contentsOf: stateURL)).flatMap { try? decoder.decode(SchedulerState.self, from: $0) }
    ?? SchedulerState(ownerID: options.owner)
  state.ownerID = options.owner
  state.claimTimeout = options.claimTimeout
  do {
    let value = try body(&state)
    if let data = try? encoder.encode(state) {
      try? data.write(to: stateURL, options: .atomic)
    }
    return value
  } catch {
    fail("\(error)")
  }
}

private func claimTick(limit: Int) -> [DeliveryClaim] {
  withState { state -> [DeliveryClaim] in
    let now = Date()
    state.reclaimExpiredClaims(now: now)
    _ = try state.acquireLease(now: now, duration: options.leaseDuration)
    return try state.claimDue(now: now, limit: limit)
  } ?? []
}

private func record(_ key: String, delivered: Bool) {
  _ = withState { state -> Bool in
    if delivered {
      try state.markDelivered(key, at: Date())
    } else {
      try state.markFailed(key, at: Date())
    }
    return true
  }
}

if let seed = options.seed {
  let seeded = withState { state -> Bool in
    guard state.job(named: seed.title) == nil else { return false }
    try state.addJob(
      botID: seed.bot, title: seed.title, prompt: seed.prompt, cadence: seed.cadence,
      startAt: Date())
    return true
  }
  if seeded == true { print("SEEDED \(seed.title) every \(Int(seed.cadence))s") }
}

if options.execCommand == nil {
  print("NO_EXEC_COMMAND (deliveries are recorded, not sent)")
}

let opened = withState { state -> Bool in
  state.reclaimExpiredClaims(now: Date())
  for record in state.unresolvedDeliveries() {
    print("UNCONFIRMED \(record.key) attempt=\(record.attempts) (not resent)")
  }
  guard try state.acquireLease(now: Date(), duration: options.leaseDuration) else {
    print("LEASE_BUSY owner=\(options.owner)")
    return false
  }
  print("LEASE owner=\(options.owner) generation=\(state.lease?.generation ?? 0)")
  return true
}
guard opened == true else { exit(3) }

private let executor: ScheduledWorkExecutor =
  options.execCommand.map { CommandExecutor(command: $0, timeout: options.execTimeout) }
  ?? RecordOnlyExecutor(url: deliveryURL)

var tick = 0
var delivered = 0
var failed = 0
while true {
  tick += 1
  let claims = claimTick(limit: options.limit)
  var claimedThisTick = 0
  for claim in claims {
    claimedThisTick += 1
    print(
      "CLAIM key=\(claim.deliveryKey) attempt=\(claim.attempt) bot=\(claim.botID) title=\(claim.title)"
    )
    if let limit = options.crashAfterClaims, claimedThisTick >= limit {
      print("CRASH_BEFORE_DELIVERY key=\(claim.deliveryKey)")
      exit(9)
    }
    do {
      try await executor.execute(claim)
      record(claim.deliveryKey, delivered: true)
      delivered += 1
      print("DELIVERED key=\(claim.deliveryKey)")
    } catch {
      record(claim.deliveryKey, delivered: false)
      failed += 1
      print("FAILED key=\(claim.deliveryKey) error=\(error)")
    }
  }
  if options.once || options.ticks.map({ tick >= $0 }) == true { break }
  Thread.sleep(forTimeInterval: options.interval)
}
let unconfirmed = withState { state in state.unresolvedDeliveries().count } ?? 0
print("DONE delivered=\(delivered) failed=\(failed) unconfirmed=\(unconfirmed)")
