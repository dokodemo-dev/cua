// SPDX-License-Identifier: FSL-1.1-MIT
// One scheduled delivery, run against the real engine. The scheduler passes the
// claim through the environment; this process starts or continues the Bot's run
// and exits non-zero when it could not.
import Cua
import CuaBotsCore
import CuaBotsCua
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

func fail(_ message: String, code: Int32 = 2) -> Never {
  FileHandle.standardError.write(Data("error: \(message)\n".utf8))
  exit(code)
}

var volumeRoot: String?
var dataDirectory: String?
var stateDirectory: String?
var spacesDirectory: String?
var teleportDirectory: String?
var dryRun = false
var showHelp = false

var index = 1
let arguments = CommandLine.arguments
while index < arguments.count {
  func value() -> String {
    guard index + 1 < arguments.count else { fail("\(arguments[index]) needs a value") }
    index += 1
    return arguments[index]
  }
  switch arguments[index] {
  case "--volume": volumeRoot = value()
  case "--data": dataDirectory = value()
  case "--state": stateDirectory = value()
  case "--spaces": spacesDirectory = value()
  case "--teleport": teleportDirectory = value()
  case "--dry-run": dryRun = true
  case "--help", "-h": showHelp = true
  default: fail("unknown flag \(arguments[index])")
  }
  index += 1
}

if showHelp {
  print(
    """
    usage: cua-bots-run --volume <dir> [--data <dir>] [--state <dir>] [--dry-run]

    Runs one scheduled delivery. The claim comes from the environment that
    cua-bots-scheduler sets:
      \(ScheduledRunnerInvocation.botKey), \(ScheduledRunnerInvocation.promptKey),
      \(ScheduledRunnerInvocation.titleKey), \(ScheduledRunnerInvocation.deliveryKeyKey),
      \(ScheduledRunnerInvocation.attemptKey)

    Nothing is started with --dry-run: the planned action is printed and the
    process exits 0. A refused delivery exits 3, a failed one exits 1.
    """)
  exit(0)
}

let invocation: ScheduledRunnerInvocation
do {
  invocation = try ScheduledRunnerInvocation.fromEnvironment(ProcessInfo.processInfo.environment)
} catch {
  fail("bad environment: \(error)")
}

guard let volumeRoot else { fail("--volume is required") }
let volume = LocalVolume(root: URL(fileURLWithPath: volumeRoot))
let data = URL(
  fileURLWithPath: dataDirectory
    ?? URL(fileURLWithPath: volumeRoot).deletingLastPathComponent()
    .appendingPathComponent("data").path)

if dryRun {
  // No runtime and no identity decoding: this only proves the claim survived the
  // scheduler's environment contract.
  let identity = volumeRoot + "/" + VolumeLayout.identity(invocation.botID)
  let present = FileManager.default.fileExists(atPath: identity)
  print("DRY_RUN bot=\(invocation.botID) attempt=\(invocation.attempt) identity=\(present)")
  print("PROMPT \(invocation.prompt)")
  exit(0)
}

@MainActor
func run() async -> Int32 {
  do {
    let cua: Cua
    if let stateDirectory, let spacesDirectory, let teleportDirectory {
      cua = try Cua.embedded(
        stateDir: stateDirectory, spacesHome: spacesDirectory, teleportHome: teleportDirectory)
    } else {
      cua = try Cua.embedded()
    }
    let engine = CuaEngine(cua: cua)
    let store = BotStore(volume: volume, dataDirectory: data, engine: engine)
    defer { store.disconnect() }
    guard let bot = store.bot(invocation.botID) else {
      FileHandle.standardError.write(Data("error: unknown Bot\n".utf8))
      return 3
    }
    let executor = EngineScheduledExecutor(engine: engine, volume: volume) { id in
      store.bot(id)
    }
    try await executor.execute(invocation.claim)
    print("DELIVERED bot=\(invocation.botID) key=\(invocation.deliveryKey)")
    return 0
  } catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    return 1
  }
}

exit(await run())
