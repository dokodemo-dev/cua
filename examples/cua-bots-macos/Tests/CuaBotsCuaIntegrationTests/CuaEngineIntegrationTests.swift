// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import Cua
import CuaBotsCore
import CuaBotsCua
import Foundation
import Testing

@MainActor
struct CuaEngineIntegrationTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["CUA_BOTS_RUN_CUA_INTEGRATION"] == "1"))
  func piRunsThroughCuaEngineAndResumesAfterSuspend() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["OPENAI_API_KEY"]?.hasPrefix("test-") == true else {
      Issue.record("Set OPENAI_API_KEY to a non-production test placeholder beginning with test-")
      return
    }

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("cua-bots-engine-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let cua = try Cua.embedded(
      stateDir: root.appendingPathComponent("state").path,
      spacesHome: root.appendingPathComponent("spaces").path,
      teleportHome: root.appendingPathComponent("teleport").path)
    let engine = CuaEngine(
      cua: cua,
      endpoint: ModelEndpoint(
        baseURL: "http://127.0.0.1:18788/v1",
        model: "test-model",
        keyVariables: ["OPENAI_API_KEY"]))
    engine.image = "ghcr.io/trycua/linux:24.04"
    engine.suspendOnPause = true

    var bot = Bot(name: "integration-\(UUID().uuidString)", owner: "integration-test")
    do {
      bot.spaceID = try await engine.provision(bot) { _ in }
      let space = try await engine.space(bot)
      try await startMock(in: space)

      let volume = LocalVolume(root: root.appendingPathComponent("volume"))
      var cursor = UInt64(0)
      print("CuaEngine integration: starting first turn")
      bot.runID = try await engine.start(
        bot, volume: volume, prompt: "Reply with a short greeting.")
      let first = try await waitForReply(
        engine: engine, bot: bot, space: space, cursor: cursor)
      cursor = first.cursor
      #expect(first.text.contains("CuaEngine mock reply."))
      print("CuaEngine integration: first turn completed; suspending and resuming")

      try await engine.pause(bot)
      try await engine.resume(bot)
      try await engine.send(bot, text: "Reply once more.")
      let second = try await waitForReply(
        engine: engine, bot: bot, space: space, cursor: cursor)
      #expect(second.text.contains("CuaEngine mock reply."))
      #expect(bot.runID != nil)
    } catch {
      try? await engine.reset(bot)
      throw error
    }

    try await engine.reset(bot)
  }

  private func startMock(in space: CuaSDK.Space) async throws {
    let source = #"""
      import { createServer } from "node:http";
      import { writeFileSync } from "node:fs";

      const model = "test-model";
      const answer = "CuaEngine mock reply.";
      let requestCount = 0;
      const server = createServer(async (request, response) => {
        if (request.method === "GET" && request.url === "/health") {
          response.writeHead(200, { "content-type": "application/json" });
          response.end("{}");
          return;
        }
        if (request.method === "GET" && request.url === "/v1/models") {
          response.writeHead(200, { "content-type": "application/json" });
          response.end(JSON.stringify({ object: "list", data: [{ id: model, object: "model", created: 0, owned_by: "local" }] }));
          return;
        }
        if (request.method !== "POST" || request.url !== "/v1/chat/completions") {
          response.writeHead(404);
          response.end();
          return;
        }

        let body = "";
        for await (const part of request) body += part;
        const input = JSON.parse(body);
        requestCount += 1;
        writeFileSync("/tmp/cua-bots-engine-mock-count", String(requestCount));
        const id = "chatcmpl-cua-bots-test";
        if (input.stream !== true) {
          response.writeHead(200, { "content-type": "application/json" });
          response.end(JSON.stringify({
            id,
            object: "chat.completion",
            created: 0,
            model,
            choices: [{ index: 0, message: { role: "assistant", content: answer }, finish_reason: "stop" }],
            usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
          }));
          return;
        }

        response.writeHead(200, {
          "content-type": "text/event-stream",
          "cache-control": "no-cache",
          connection: "keep-alive",
        });
        const send = (delta, finishReason = null) => response.write(`data: ${JSON.stringify({
          id,
          object: "chat.completion.chunk",
          created: 0,
          model,
          choices: [{ index: 0, delta, finish_reason: finishReason }],
        })}\n\n`);
        send({ role: "assistant", content: "" });
        send({ content: answer });
        send({}, "stop");
        response.end("data: [DONE]\n\n");
      });
      server.listen(18788, "127.0.0.1");
      """#

    _ = try await space.write(path: "/tmp/cua-bots-engine-mock.mjs", content: Data(source.utf8))
    let launch = try await space.bash(
      command:
        "node --version >/dev/null && (nohup node /tmp/cua-bots-engine-mock.mjs >/tmp/cua-bots-engine-mock.log 2>&1 </dev/null &)",
      timeoutMs: 10_000)
    guard launch.exitCode == 0 else { throw IntegrationError.mockDidNotStart }

    for _ in 0..<50 {
      let probe = try await space.bash(
        command:
          "node -e 'fetch(\"http://127.0.0.1:18788/health\").then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))'",
        timeoutMs: 2_000)
      if probe.exitCode == 0 { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw IntegrationError.mockDidNotStart
  }

  private func waitForReply(
    engine: CuaEngine,
    bot: Bot,
    space: CuaSDK.Space,
    cursor initialCursor: UInt64
  ) async throws -> (text: String, cursor: UInt64) {
    var cursor = initialCursor
    var text = ""
    for _ in 0..<300 {
      let page = try await engine.poll(bot, cursor: cursor)
      cursor = page.cursor
      for update in page.updates {
        switch update {
        case .assistant(_, let content): text = content
        case .failed(let reason): throw IntegrationError.agentFailed(reason)
        case .turnEnded: return (text, cursor)
        case .tool: break
        }
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    let run = bot.runID ?? ""
    let raw = try? await space.agentEvents(runId: run, cursor: 0, max: 500)
    let page =
      raw.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
    let events = page?["events"] as? [[String: Any]] ?? []
    let kinds = events.compactMap { $0["kind"] as? String }.joined(separator: ",")
    let countResult = try? await space.bash(
      command: "cat /tmp/cua-bots-engine-mock-count 2>/dev/null || printf 0",
      timeoutMs: 2_000)
    let requestCount =
      Int(countResult?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    throw IntegrationError.replyTimedOut(
      cursor: cursor, eventKinds: kinds, mockRequests: requestCount)
  }

  private enum IntegrationError: Error {
    case mockDidNotStart
    case agentFailed(String)
    case replyTimedOut(cursor: UInt64, eventKinds: String, mockRequests: Int)
  }
}
