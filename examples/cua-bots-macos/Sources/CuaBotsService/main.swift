import CuaBotsCore
// SPDX-License-Identifier: FSL-1.1-MIT
// Isolated demo service: seeds one shared Space and two Bots, then serves the
// local API. Tokens are written with 0600 and never printed.
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

private func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("error: \(message)\n".utf8))
  exit(2)
}

var stateDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
var requestedPort: UInt16 = 0
var printLaunchdPlist = false
var rotateBot: String?
var revokeBot: String?
var mintBot: String?
var advertiseHost = "host.docker.internal"
var index = 1
let arguments = CommandLine.arguments
while index < arguments.count {
  switch arguments[index] {
  case "--state":
    guard index + 1 < arguments.count else { fail("--state needs a value") }
    stateDirectory = URL(fileURLWithPath: arguments[index + 1])
    index += 2
  case "--print-launchd-plist":
    printLaunchdPlist = true
    index += 1
  case "--advertise-host":
    guard index + 1 < arguments.count else { fail("--advertise-host needs a host") }
    advertiseHost = arguments[index + 1]
    index += 2
  case "--mint":
    guard index + 1 < arguments.count else { fail("--mint needs a Bot id") }
    mintBot = arguments[index + 1]
    index += 2
  case "--revoke":
    guard index + 1 < arguments.count else { fail("--revoke needs a Bot id") }
    revokeBot = arguments[index + 1]
    index += 2
  case "--rotate":
    guard index + 1 < arguments.count else { fail("--rotate needs a Bot id") }
    rotateBot = arguments[index + 1]
    index += 2
  case "--port":
    guard index + 1 < arguments.count, let port = UInt16(arguments[index + 1]) else {
      fail("--port needs a number")
    }
    requestedPort = port
    index += 2
  default:
    fail("unknown flag \(arguments[index])")
  }
}
try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

/// Absolute path of this executable, so the plist does not depend on PATH.
func programPath() -> String {
  let raw = CommandLine.arguments.first ?? ""
  let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  return URL(fileURLWithPath: raw, relativeTo: base).standardized.path
}

if printLaunchdPlist {
  let job = ServiceLaunchd.Job(
    label: "ai.cua.bots.service", program: programPath(),
    arguments: ["--state", stateDirectory.path], stateDirectory: stateDirectory.path)
  do {
    print(try ServiceLaunchd.propertyList(job), terminator: "")
    exit(0)
  } catch {
    fail("cannot render the launchd job: \(error)")
  }
}

let spaceID = "local:shared"
let trustGroup = "team-a"

/// What a Bot may do. Registry management is deliberately absent: only the
/// administrator credential can mint tokens.
let botCapabilities: Set<Capability> = [
  .spacesRead, .screenControl, .artifactsRead, .artifactsWrite, .delegate,
]
let stateStore = ServiceStateStore(directory: stateDirectory)

/// The demo Space layout is created only for a fresh state directory.
func seed_registry() throws -> ExecutionRegistry {
  var registry = ExecutionRegistry()
  try registry.addTarget(ExecutionTarget(id: "local", name: "This Mac", kind: .local))
  try registry.addBinding(
    SpaceBinding(
      spaceID: spaceID, targetID: "local", mode: .shared, managedByApp: false,
      trustGroup: trustGroup))
  for bot in ["alpha", "beta"] {
    try registry.assign(
      botID: bot, spaceID: spaceID, workingDirectory: "/home/cua/bots/\(bot)",
      trustGroup: trustGroup)
  }
  // A second Space in another trust group, to check that sharing stays closed.
  try registry.addBinding(
    SpaceBinding(
      spaceID: "local:other", targetID: "local", mode: .shared, managedByApp: false,
      trustGroup: "team-b"))
  try registry.assign(
    botID: "stranger", spaceID: "local:other", workingDirectory: "/home/cua/bots/stranger",
    trustGroup: "team-b")
  return registry
}

func writeToken(_ token: String, for bot: String) throws {
  let path = stateDirectory.appendingPathComponent("\(bot).token")
  try Data(token.utf8).write(to: path, options: [.atomic])
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
}

if let mintBot {
  guard var state = try stateStore.load() else {
    fail("no service state in \(stateDirectory.path)")
  }
  guard let binding = state.registry.bindings.values.first(where: { $0.botIDs.contains(mintBot) })
  else { fail("unknown Bot: \(mintBot)") }
  var tokens = TokenStore(snapshot: state.tokens)
  let issued = try tokens.issue(
    botID: mintBot, trustGroup: binding.trustGroup, spaceID: binding.spaceID,
    capabilities: botCapabilities, now: Date(), lifetime: 3600)
  state.tokens = tokens.snapshot
  try stateStore.save(state)
  try writeToken(issued, for: mintBot)
  print("MINTED \(mintBot) -> \(stateDirectory.path)/\(mintBot).token")
  exit(0)
}

if let revokeBot {
  guard var state = try stateStore.load() else {
    fail("no service state in \(stateDirectory.path)")
  }
  guard state.registry.bindings.values.contains(where: { $0.botIDs.contains(revokeBot) }) else {
    fail("unknown Bot: \(revokeBot)")
  }
  var tokens = TokenStore(snapshot: state.tokens)
  tokens.revokeAll(botID: revokeBot, now: Date())
  state.tokens = tokens.snapshot
  try stateStore.save(state)
  print("REVOKED \(revokeBot)")
  exit(0)
}

if let rotateBot {
  guard var state = try stateStore.load() else {
    fail("no service state in \(stateDirectory.path)")
  }
  guard state.registry.bindings.values.contains(where: { $0.botIDs.contains(rotateBot) }) else {
    fail("unknown Bot: \(rotateBot)")
  }
  var tokens = TokenStore(snapshot: state.tokens)
  tokens.revokeAll(botID: rotateBot, now: Date())
  let token = try tokens.issue(
    botID: rotateBot, trustGroup: "team-a", spaceID: spaceID,
    capabilities: botCapabilities, now: Date(), lifetime: 3600)
  state.tokens = tokens.snapshot
  try stateStore.save(state)
  try writeToken(token, for: rotateBot)
  print("ROTATED \(rotateBot) (previous tokens are revoked)")
  exit(0)
}

var api: ServiceAPI
if let existing = try stateStore.load() {
  api = ServiceAPI.api(for: existing, store: stateStore)
  print(
    "RESTORED tasks=\(existing.collaboration.taskCount) messages=\(existing.collaboration.messageCount) artifacts=\(existing.collaboration.artifactCount)"
  )
  // Token strings are stored only as hashes, so a lost file cannot be replaced.
  for bot in ["alpha", "beta", "stranger"] {
    if !FileManager.default.fileExists(
      atPath: stateDirectory.appendingPathComponent("\(bot).token").path)
    {
      print("MISSING_TOKEN \(bot) (issue a new one to keep using this Bot)")
    }
  }
} else {
  let registry = try seed_registry()
  var tokens = TokenStore()
  var fresh = ServiceAPI(
    registry: registry, tokens: tokens,
    collaboration: CollaborationService(
      authorization: AuthorizationPolicy(registry: registry), registry: registry))
  for bot in ["alpha", "beta", "stranger"] {
    let token = try tokens.issue(
      botID: bot, trustGroup: bot == "stranger" ? "team-b" : trustGroup,
      spaceID: bot == "stranger" ? "local:other" : spaceID,
      capabilities: botCapabilities, now: Date(), lifetime: 3600)
    try writeToken(token, for: bot)
  }
  let admin = try tokens.issue(
    botID: "admin", trustGroup: trustGroup, spaceID: nil, capabilities: [.manageRegistry],
    now: Date(), lifetime: 3600)
  try writeToken(admin, for: "admin")
  fresh.tokens = tokens
  fresh.store = stateStore
  fresh.persist()
  api = fresh
  print("ADMIN \(stateDirectory.path)/admin.token (host only)")
}

let server = ServiceServer(api: api, requestedPort: requestedPort)
let port = try server.start()
try Data("\(port)\n".utf8).write(
  to: stateDirectory.appendingPathComponent("port"), options: .atomic)
let advertised = "http://\(advertiseHost):\(port)"
try Data("\(advertised)\n".utf8).write(
  to: stateDirectory.appendingPathComponent("api-url"), options: .atomic)
print("LISTEN 127.0.0.1:\(port)")
print("ADVERTISED \(advertised)")
print("BOTS alpha beta stranger")
print("TOKENS \(stateDirectory.path)/<bot>.token")

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let stop = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
stop.setEventHandler {
  server.stop()
  print("STOPPED")
  exit(0)
}
stop.resume()
RunLoop.main.run()
