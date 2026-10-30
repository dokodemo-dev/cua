// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import Foundation
import Combine

/// Posts a notification where the user will see it (the system on macOS and
/// iOS, the in-app list always).
@MainActor
public protocol Notifier: AnyObject {
    func post(_ notification: BotNotification, bot: Bot)
}

/// Signs a bot into a site without the model seeing the password: the
/// macOS app answers it with the Keyvault.
@MainActor
public protocol SignInBroker: AnyObject {
    /// Deliver the user's saved sign-in for `site` into the bot's Space.
    /// Throws when the user declines or there is no saved sign-in.
    func signIn(bot: Bot, site: String) async throws -> String
}

/// The app's state: bots, their conversations, work, approvals and
/// notifications. A bot's identity, rules, memory and scheduled work live in
/// the Volume (`agents/<name>/`); conversations and notifications live in the
/// app's data folder.
@MainActor
public final class BotStore: ObservableObject {
    @Published public private(set) var bots: [Bot] = []
    @Published public private(set) var executions = ExecutionRegistry()
    @Published public private(set) var messages: [String: [ChatMessage]] = [:]
    @Published public private(set) var tasks: [String: [BotTask]] = [:]
    @Published public private(set) var rules: [String: [CustomRule]] = [:]
    @Published public private(set) var approvals: [ApprovalRequest] = []
    @Published public private(set) var notifications: [BotNotification] = []
    /// Set while a bot is being created: what the engine is doing.
    @Published public private(set) var setupPhase: [String: String] = [:]
    @Published public var lastError: String?

    public let volume: VolumeStore
    public let dataDirectory: URL
    public var engine: BotEngine?
    public weak var notifier: Notifier?
    public weak var signIn: SignInBroker?
    /// Called when a bot's scheduled tasks change, so the routine clock can
    /// follow.
    public var onTasksChanged: ((Bot, [BotTask]) -> Void)?

    private var cursors: [String: UInt64] = [:]
    private var turnText: [String: (turn: UInt32, text: String)] = [:]
    private var pollers: [String: Task<Void, Never>] = [:]
    private var currentTask: [String: String] = [:]
    private var busy: Set<String> = []
    private var changing: Set<String> = []
    private var polling: Set<String> = []
    /// Turns that ended in a failure: the next message polls instead of
    /// inventing a new turn, and a clean exit does not report success.
    private var failedTurns: Set<String> = []
    private var pollFailures: [String: Int] = [:]

    public init(volume: VolumeStore, dataDirectory: URL, engine: BotEngine? = nil) {
        self.volume = volume
        self.dataDirectory = dataDirectory
        self.engine = engine
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Reading

    public func bot(_ id: String) -> Bot? { bots.first { $0.id == id } }
    public func messages(for id: String) -> [ChatMessage] { messages[id] ?? [] }
    public func tasks(for id: String) -> [BotTask] { tasks[id] ?? [] }
    public func rules(for id: String) -> [CustomRule] { rules[id] ?? CustomRule.defaults }
    public func pendingApprovals(for id: String? = nil) -> [ApprovalRequest] {
        approvals.filter { $0.state == .pending && (id == nil || $0.botID == id) }
    }
    public func approval(_ id: String) -> ApprovalRequest? { approvals.first { $0.id == id } }
    public var unreadCount: Int { notifications.filter { !$0.read }.count }
    public func isBusy(_ id: String) -> Bool { busy.contains(id) || changing.contains(id) }

    /// The bot's memory file, as the Volume has it.
    public func memory(for id: String) -> String {
        (try? volume.readText(VolumeLayout.memory(id))) ?? ""
    }

    /// Finished files under `agents/<name>/outputs/`.
    public func outputs(for id: String) -> [VolumeEntry] {
        (try? volume.walk(VolumeLayout.outputs(id))) ?? []
    }

    // MARK: - Creating

    /// Create a bot: write its home to the Volume, give it its own Space and
    /// start its agent, which introduces itself.
    @discardableResult
    public func createBot(name: String, avatar: AvatarConfig, harness: Harness,
                          placement: Placement, runtime: BotRuntime? = nil,
                          existingSpace: ExistingSpaceAssignment? = nil) async -> Bot {
        var bot = Bot(name: name, avatar: avatar, harness: harness, placement: placement, runtime: runtime)
        var n = 2
        while bots.contains(where: { $0.id == bot.id }) {
            bot.id = Bot.agentName(for: "\(name)-\(n)")
            n += 1
        }
        if var existingSpace {
            if existingSpace.workingDirectory.trimmingCharacters(in: .whitespaces).isEmpty {
                existingSpace.workingDirectory = "/home/cua/bots/\(bot.id)"
            }
            do {
                try attach(bot.id, to: existingSpace)
            } catch {
                lastError = "Can't use that Space: \(error)"
                return bot
            }
            bot.spaceID = existingSpace.spaceID
            bot.executionTargetID = existingSpace.targetID
            bot.trustGroup = existingSpace.trustGroup
            var runtime = bot.runtime ?? BotRuntime()
            runtime.workingDirectory = existingSpace.workingDirectory
            bot.runtime = runtime
        }
        bots.append(bot)
        rules[bot.id] = CustomRule.defaults
        writeHome(bot)
        append(ChatMessage(botID: bot.id, role: .bot,
                           text: "Hi, I'm \(bot.name). I'm setting up my computer; I'll say hello when I'm ready."))
        save()
        await bringUp(bot.id, firstPrompt: Self.introPrompt(bot))
        return self.bot(bot.id) ?? bot
    }

    /// Register the target, reuse or create the shared binding, then assign.
    /// The Bot is not added to the store when this throws.
    private func attach(_ botID: String, to assignment: ExistingSpaceAssignment) throws {
        var next = executions
        if next.targets[assignment.targetID] == nil {
            try next.addTarget(ExecutionTarget(
                id: assignment.targetID, name: assignment.targetName, kind: .local))
        }
        if let binding = next.bindings[assignment.spaceID] {
            guard binding.targetID == assignment.targetID,
                  binding.trustGroup == assignment.trustGroup else {
                throw ExecutionRegistryError.trustGroupMismatch
            }
        } else {
            try next.addBinding(SpaceBinding(
                spaceID: assignment.spaceID, targetID: assignment.targetID, mode: .shared,
                managedByApp: false, trustGroup: assignment.trustGroup))
        }
        try next.assign(
            botID: botID, spaceID: assignment.spaceID,
            workingDirectory: assignment.workingDirectory, trustGroup: assignment.trustGroup)
        executions = next
    }

    static func introPrompt(_ bot: Bot) -> String {
        "You were just created. Introduce yourself to \(bot.owner) in two short sentences as \(bot.name): "
            + "say you have your own computer, you'll keep working when they're away, and you'll check in "
            + "when something needs their approval. Then start your memory file with one line about today."
    }

    private func bringUp(_ id: String, firstPrompt: String) async {
        guard let engine, var bot = bot(id), !changing.contains(id) else { return }
        changing.insert(id)
        defer { changing.remove(id) }
        do {
            try bot.runtime?.validate()
            update(id) { $0.status = "Setting up"; $0.mood = .working }
            let space: String
            if let existing = bot.spaceID {
                space = existing
            } else {
                space = try await engine.provision(bot) { [weak self] phase in
                    guard let self else { return }
                    switch phase {
                    case .creatingSpace(let s): self.setupPhase[id] = s
                    case .startingAgent: self.setupPhase[id] = "Starting \(bot.harness.name)"
                    case .ready: self.setupPhase[id] = nil
                    }
                }
            }
            update(id) { $0.spaceID = space }
            bot = self.bot(id) ?? bot
            if bot.executionTargetID == nil {
                let targetID = "local"
                if executions.targets[targetID] == nil {
                    try executions.addTarget(ExecutionTarget(id: targetID, name: bot.placement.name, kind: bot.placement == .local ? .local : .legacyCloud))
                }
                try executions.addBinding(SpaceBinding(spaceID: space, targetID: targetID, mode: .exclusive, managedByApp: true, trustGroup: bot.effectiveTrustGroup))
                try executions.assign(botID: id, spaceID: space, workingDirectory: bot.runtime?.workingDirectory.isEmpty == false ? bot.runtime!.workingDirectory : "/home/cua/bots/\(id)", trustGroup: bot.effectiveTrustGroup)
                update(id) { $0.executionTargetID = targetID }
                bot = self.bot(id) ?? bot
            }
            let run = try await engine.start(bot, volume: volume, prompt: firstPrompt)
            cursors[id] = nil
            turnText[id] = nil
            update(id) { $0.runID = run; $0.status = "Thinking"; $0.mood = .thinking }
            setupPhase[id] = nil
            busy.insert(id)
            startPolling(id)
        } catch {
            setupPhase[id] = nil
            fail(id, "Couldn't set up \(bot.name)'s computer: \(error.localizedDescription)")
        }
        save()
    }

    /// Reconnect to bots that were running when the app last quit.
    public func reconnect() {
        for bot in bots where bot.runID != nil && !bot.isPaused { startPolling(bot.id) }
    }

    // MARK: - Customizing

    /// Settings apply to a new run, never to an old harness session.
    @discardableResult
    public func configure(_ id: String, harness: Harness, runtime: BotRuntime) async -> Bool {
        guard let bot = bot(id), !busy.contains(id), !changing.contains(id), setupPhase[id] == nil else {
            lastError = "Wait for the bot's current turn to finish."
            return false
        }
        do {
            try runtime.validate()
            if bot.harness == harness && (bot.runtime ?? BotRuntime()) == runtime { return true }
            changing.insert(id)
            defer { changing.remove(id) }
            if bot.runID != nil {
                guard let engine else { throw CocoaError(.featureUnsupported) }
                try await engine.stop(bot)
            }
            pollers[id]?.cancel()
            pollers[id] = nil
            cursors[id] = nil
            turnText[id] = nil
            update(id) {
                $0.harness = harness
                $0.runtime = runtime
                $0.runID = nil
                $0.mood = $0.isPaused ? .paused : .idle
                $0.status = "Settings saved; send a message to start"
            }
            if let changed = self.bot(id) { writeHome(changed) }
            save()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Release background pollers without interrupting guest sessions.
    public func disconnect() {
        for poller in pollers.values { poller.cancel() }
        pollers.removeAll()
    }

    public func updateAvatar(_ id: String, _ avatar: AvatarConfig) {
        update(id) { $0.avatar = avatar }
        writeHome(bot(id)!)
        save()
    }

    public func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = trimmed }
        writeHome(bot(id)!)
        save()
    }

    public func setRules(_ id: String, _ list: [CustomRule]) {
        // Locked rules always stay, whatever the editor sends back.
        let locked = CustomRule.defaults.filter(\.locked)
        rules[id] = locked + list.filter { !$0.locked }
        if let b = bot(id) { writeHome(b) }
    }

    public func setHostAccess(_ id: String, _ access: HostAccess) {
        update(id) { $0.hostAccess = access }
        save()
    }

    // MARK: - Talking

    public func send(_ id: String, _ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let bot = bot(id) else { return }
        append(ChatMessage(botID: id, role: .user, text: text))
        guard !bot.isPaused else {
            append(ChatMessage(botID: id, role: .system, text: "\(bot.name) is paused. Resume to continue.",
                               kind: .notice))
            return
        }
        await deliver(id, text)
    }

    private func deliver(_ id: String, _ text: String) async {
        guard let engine, let bot = bot(id) else { return }
        if failedTurns.contains(id) { await pollOnce(id) }
        failedTurns.remove(id)
        pollFailures[id] = 0
        guard !changing.contains(id) else {
            lastError = "Wait for the bot's settings or startup operation to finish."
            return
        }
        do {
            if bot.runID == nil {
                await bringUp(id, firstPrompt: text)
            } else {
                try? await engine.push(bot, volume: volume)
                try await engine.send(bot, text: text)
                busy.insert(id)
                update(id) { $0.mood = .thinking; $0.status = "Thinking" }
                startPolling(id)
            }
        } catch {
            fail(id, "Couldn't reach \(bot.name): \(error.localizedDescription)")
        }
        save()
    }

    // MARK: - Approvals

    /// Approve or deny. The bot hears back in its conversation; a sign-in is
    /// delivered through the Keyvault first.
    public func decide(_ approvalID: String, approve: Bool) async {
        guard let i = approvals.firstIndex(where: { $0.id == approvalID }),
              approvals[i].state == .pending else { return }
        var a = approvals[i]
        a.decidedAt = Date()
        let botID = a.botID
        if !approve {
            a.state = .denied
            approvals[i] = a
            refreshMood(botID)
            await deliver(botID, "Denied: \(a.action). Don't do it; tell me what you'll do instead.")
            return
        }
        switch a.source {
        case .login(let site):
            do {
                guard let broker = signIn, let bot = bot(botID) else { throw SignInError.unavailable }
                let how = try await broker.signIn(bot: bot, site: site)
                a.state = .approved
                approvals[i] = a
                refreshMood(botID)
                await deliver(botID, "Signed in to \(site) (\(how)). Continue.")
            } catch {
                lastError = "Sign-in for \(site) didn't go through: \(error.localizedDescription)"
            }
        case .handOff:
            a.state = .handedOff
            approvals[i] = a
            refreshMood(botID)
            await deliver(botID, "I did it myself: \(a.action). Carry on from there.")
        default:
            a.state = .approved
            approvals[i] = a
            refreshMood(botID)
            await deliver(botID, "Approved: \(a.action). Go ahead, only this once.")
        }
        save()
    }

    public enum SignInError: LocalizedError {
        case unavailable
        public var errorDescription: String? { "Saved sign-ins aren't available here." }
    }

    // The service is the intended owner of these mutations. Never expose these
    // methods directly to an untrusted Bot without an authorization check.
    public func registerTarget(_ target: ExecutionTarget) throws {
        try executions.addTarget(target)
        save()
    }

    public func registerBinding(_ binding: SpaceBinding) throws {
        try executions.addBinding(binding)
        save()
    }

    @discardableResult
    public func assign(_ id: String, to spaceID: String, workingDirectory: String) async -> Bool {
        guard let bot = bot(id), !isBusy(id), setupPhase[id] == nil else {
            lastError = "Wait for the bot's current operation to finish."
            return false
        }
        changing.insert(id)
        defer { changing.remove(id) }
        do {
            var next = executions
            if let old = bot.spaceID { _ = try next.detach(botID: id, spaceID: old) }
            try next.assign(botID: id, spaceID: spaceID, workingDirectory: workingDirectory, trustGroup: bot.effectiveTrustGroup)
            guard let binding = next.bindings[spaceID] else { throw ExecutionRegistryError.unknownSpace }
            guard let engine else { throw CocoaError(.featureUnsupported) }
            if bot.runID != nil { try await engine.stop(bot) }
            pollers[id]?.cancel()
            pollers[id] = nil
            cursors[id] = nil
            turnText[id] = nil
            executions = next
            update(id) {
                $0.executionTargetID = binding.targetID
                $0.spaceID = spaceID
                $0.runID = nil
                var runtime = $0.runtime ?? BotRuntime()
                runtime.workingDirectory = workingDirectory
                $0.runtime = runtime
                $0.status = "Execution target saved; send a message to start"
                $0.mood = $0.isPaused ? .paused : .idle
            }
            if let updated = self.bot(id) { writeHome(updated) }
            save()
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    private func ownsExclusiveSpace(_ bot: Bot) -> Bool {
        guard let id = bot.spaceID, let binding = executions.bindings[id] else { return false }
        return binding.managedByApp && binding.mode == .exclusive && binding.botIDs == [bot.id]
    }

    // MARK: - Pause, resume, reset

    public func pause(_ id: String) async {
        guard let bot = bot(id), !bot.isPaused, !changing.contains(id) else { return }
        update(id) { $0.isPaused = true; $0.mood = .paused; $0.status = "Paused" }
        pollers[id]?.cancel()
        pollers[id] = nil
        busy.remove(id)
        setTasks(id) { list in
            for i in list.indices where list[i].schedule != nil && list[i].state == .scheduled {
                list[i].state = .paused
            }
        }
        do {
            if ownsExclusiveSpace(bot) { try await engine?.pause(bot) }
            else { try await engine?.interrupt(bot) }
        } catch { lastError = error.localizedDescription }
        save()
    }

    public func resume(_ id: String) async {
        guard let bot = bot(id), bot.isPaused, !changing.contains(id) else { return }
        do { if ownsExclusiveSpace(bot) { try await engine?.resume(bot) } }
        catch { lastError = error.localizedDescription; return }
        update(id) { $0.isPaused = false; $0.mood = .idle; $0.status = "Ready" }
        setTasks(id) { list in
            for i in list.indices where list[i].state == .paused { list[i].state = .scheduled }
        }
        startPolling(id)
        save()
    }

    /// Delete the bot: its run, Space, conversation, memory and schedule.
    public func reset(_ id: String) async {
        guard let bot = bot(id), !changing.contains(id) else { return }
        pollers[id]?.cancel()
        pollers[id] = nil
        changing.insert(id)
        defer { changing.remove(id) }
        do {
            var next = executions
            let effect: ExecutionRegistry.DetachEffect
            if let spaceID = bot.spaceID, next.bindings[spaceID] != nil {
                effect = try next.detach(botID: id, spaceID: spaceID)
            } else { effect = .preserve }
            if effect == .deleteOwnedSpace {
                guard let engine else { throw CocoaError(.featureUnsupported) }
                try await engine.reset(bot)
                if let spaceID = bot.spaceID { try next.confirmOwnedSpaceDeleted(spaceID) }
            } else if bot.runID != nil {
                guard let engine else { throw CocoaError(.featureUnsupported) }
                try await engine.stop(bot)
            }
            executions = next
        } catch { lastError = error.localizedDescription; return }
        cursors[id] = nil
        turnText[id] = nil
        currentTask[id] = nil
        busy.remove(id)
        setupPhase[id] = nil
        try? volume.delete(VolumeLayout.home(id))
        bots.removeAll { $0.id == id }
        messages[id] = nil
        tasks[id] = nil
        rules[id] = nil
        approvals.removeAll { $0.botID == id }
        notifications.removeAll { $0.botID == id }
        onTasksChanged?(bot, [])
        save()
    }

    // MARK: - Scheduled work

    @discardableResult
    public func schedule(_ id: String, title: String, prompt: String, schedule: TaskSchedule,
                         symbol: String = "clock", notify: Bool = true) -> BotTask {
        let task = BotTask(botID: id, title: title, prompt: prompt, symbol: symbol,
                           state: bot(id)?.isPaused == true ? .paused : .scheduled,
                           schedule: schedule, notifyOnCompletion: notify)
        setTasks(id) { $0.append(task) }
        return task
    }

    public func updateTask(_ task: BotTask) {
        setTasks(task.botID) { list in
            if let i = list.firstIndex(where: { $0.id == task.id }) { list[i] = task }
        }
    }

    public func deleteTask(_ task: BotTask) {
        setTasks(task.botID) { $0.removeAll { $0.id == task.id } }
    }

    /// Run a scheduled task now: the routine clock calls this. A paused or
    /// busy bot refuses rather than interrupts.
    public func fire(taskID: String, botID: String, now: Date = Date()) async -> Bool {
        guard let bot = bot(botID), !bot.isPaused, !isBusy(botID),
              let task = tasks(for: botID).first(where: { $0.id == taskID }) else { return false }
        setTasks(botID) { list in
            if let i = list.firstIndex(where: { $0.id == taskID }) {
                list[i].lastRun = now
                list[i].nextRun = list[i].schedule?.nextFire(after: now)
            }
        }
        currentTask[botID] = taskID
        append(ChatMessage(botID: botID, role: .system, text: "Scheduled: \(task.title)", kind: .notice))
        await deliver(botID, "[routine] \(task.title): \(task.prompt)")
        return true
    }

    // MARK: - Notifications

    public func markRead(_ id: String) {
        if let i = notifications.firstIndex(where: { $0.id == id }) { notifications[i].read = true }
        save()
    }

    public func markAllRead(bot id: String) {
        for i in notifications.indices where notifications[i].botID == id { notifications[i].read = true }
        let now = Date()
        messages[id] = messages[id]?.map { m in var m = m; if m.readAt == nil { m.readAt = now }; return m }
        save()
    }

    // MARK: - The run loop

    private func startPolling(_ id: String) {
        guard pollers[id] == nil else { return }
        pollers[id] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let idle = await self.pollOnce(id)
                try? await Task.sleep(for: .milliseconds(idle ? 2500 : 700))
            }
        }
    }

    /// Poll once; returns whether the bot is idle.
    @discardableResult
    public func pollOnce(_ id: String) async -> Bool {
        guard let engine, let bot = bot(id), bot.runID != nil else { return true }
        guard polling.insert(id).inserted else { return !busy.contains(id) }
        defer { polling.remove(id) }
        do {
            let (updates, cursor) = try await engine.poll(bot, cursor: cursors[id] ?? 0)
            guard !Task.isCancelled, self.bot(id)?.runID == bot.runID, !changing.contains(id) else { return true }
            for u in updates { handle(id, u) }
            cursors[id] = cursor
            pollFailures[id] = 0
            save()
        } catch {
            // A poll that fails once is not news; the next one retries.
            pollFailures[id, default: 0] += 1
            if pollFailures[id, default: 0] >= 3 {
                fail(id, "Couldn't read the agent's updates: \(error.localizedDescription). Send a message to retry.")
                save()
            }
        }
        return !busy.contains(id)
    }

    func handle(_ id: String, _ update: EngineUpdate) {
        switch update {
        case .turnStarted:
            failedTurns.remove(id)
            busy.insert(id)
            self.update(id) { $0.mood = .thinking; $0.status = "Thinking" }
        case .assistantDelta(let turn, let chunk):
            let previous = turnText[id].flatMap { $0.turn == turn ? $0.text : nil } ?? ""
            handle(id, .assistant(turn: turn, text: previous + chunk))
        case .assistant(let turn, let text):
            turnText[id] = (turn, text)
            // Live status from the markers seen so far.
            for d in DirectiveParser.parse(text).directives {
                if case .status(let s) = d { self.update(id) { $0.status = s } }
            }
        case .tool(_, let title):
            let t = title.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { self.update(id) { $0.status = String(t.prefix(40)); $0.mood = .working } }
        case .turnEnded(let turn):
            busy.remove(id)
            if failedTurns.contains(id) {
                // The turn already failed: its text is not an answer.
                turnText[id] = nil
            } else {
                let text =
                    turnText[id].flatMap { $0.turn == turn ? $0.text : nil } ?? turnText[id]?.text ?? ""
                turnText[id] = nil
                finishTurn(id, text)
                if let b = bot(id), let engine {
                    Task { try? await engine.checkpoint(b, volume: self.volume) }
                }
            }
        case .failed(let reason):
            fail(id, reason)
        case .exited:
            busy.remove(id)
            turnText[id] = nil
            pollers[id]?.cancel()
            pollers[id] = nil
            if !failedTurns.contains(id) { finishTurn(id, "") }
        }
    }

    /// A finished turn: show the text, act on the markers.
    func finishTurn(_ id: String, _ raw: String) {
        guard let bot = bot(id) else { return }
        let parsed = DirectiveParser.parse(raw)
        var status: String?
        var outputs: [String] = []
        var doneTitle: String?
        var cards: [ChatMessage] = []

        for d in parsed.directives {
            switch d {
            case .status(let s):
                status = s
            case .step(let s):
                touchTask(id) { t in
                    if !t.steps.contains(where: { $0.title == s }) { t.steps.append(TaskStep(title: s)) }
                }
            case .stepDone(let s):
                touchTask(id) { t in
                    if let i = t.steps.firstIndex(where: { $0.title == s }) { t.steps[i].done = true }
                    else { t.steps.append(TaskStep(title: s, done: true)) }
                }
            case .ask(let action, let detail):
                let decision = RuleEngine.decide(action, rules: rules(for: id))
                let a = ApprovalRequest(botID: id, action: action, detail: detail,
                                        source: decision.behavior == .handOff ? .handOff : .rule(ruleID: decision.rule?.id))
                approvals.append(a)
                cards.append(ChatMessage(botID: id, role: .bot, text: action, kind: .approval(id: a.id)))
                notify(bot, .approval, "\(bot.name) needs your approval", action)
            case .handOff(let action):
                let a = ApprovalRequest(botID: id, action: action, source: .handOff)
                approvals.append(a)
                cards.append(ChatMessage(botID: id, role: .bot, text: action, kind: .approval(id: a.id)))
                notify(bot, .approval, "\(bot.name) needs you to take over", action)
            case .login(let site):
                let a = ApprovalRequest(botID: id, action: "Sign in to \(site)",
                                        detail: "With your saved sign-in from the Keyvault. \(bot.name) never sees the password.",
                                        source: .login(site: site))
                approvals.append(a)
                cards.append(ChatMessage(botID: id, role: .bot, text: site, kind: .login(site: site, approvalID: a.id)))
                notify(bot, .approval, "\(bot.name) needs to sign in", site)
            case .notify(let title, let body):
                notify(bot, .result, title, body)
            case .output(let path):
                let key = path.hasPrefix("agents/") ? path : VolumeLayout.home(id) + path
                outputs.append(key)
            case .done(let title):
                doneTitle = title
            case .schedule(let schedule, let title, let prompt):
                let task = self.schedule(id, title: title, prompt: prompt, schedule: schedule)
                append(ChatMessage(botID: id, role: .system,
                                   text: "Scheduled \(title) · \(schedule.label)\(task.nextRun.map { ", next " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")",
                                   kind: .notice))
            }
        }

        if !parsed.text.isEmpty {
            append(ChatMessage(botID: id, role: .bot, text: parsed.text))
        }
        if !outputs.isEmpty || doneTitle != nil {
            touchTask(id, title: doneTitle) { t in
                t.outputs.append(contentsOf: outputs.filter { !t.outputs.contains($0) })
            }
            if let title = doneTitle {
                completeTask(id)
                append(ChatMessage(botID: id, role: .bot, text: title, kind: .result(title: title, outputs: outputs)))
            }
        }
        for c in cards { append(c) }
        update(id) {
            $0.status = status ?? (self.pendingApprovals(for: id).isEmpty ? "Ready" : "Waiting for you")
        }
        refreshMood(id, justFinished: doneTitle != nil)
    }

    private func refreshMood(_ id: String, justFinished: Bool = false) {
        guard let bot = bot(id) else { return }
        let mood: BotMood
        if bot.isPaused { mood = .paused }
        else if !pendingApprovals(for: id).isEmpty { mood = .needsApproval }
        else if busy.contains(id) { mood = .thinking }
        else if justFinished { mood = .done }
        else { mood = .idle }
        update(id) { $0.mood = mood }
    }

    private func notify(_ bot: Bot, _ kind: BotNotification.Kind, _ title: String, _ body: String) {
        let n = BotNotification(botID: bot.id, kind: kind, title: title, body: body)
        notifications.insert(n, at: 0)
        notifier?.post(n, bot: bot)
    }

    private func fail(_ id: String, _ reason: String) {
        busy.remove(id)
        turnText[id] = nil
        guard failedTurns.insert(id).inserted else { return }
        update(id) { $0.mood = .error; $0.status = "Needs a look" }
        append(ChatMessage(botID: id, role: .system, text: reason, kind: .notice))
        if let bot = bot(id) { notify(bot, .problem, "\(bot.name) hit a problem", reason) }
        if let t = currentTask[id] {
            setTasks(id) { list in
                if let i = list.firstIndex(where: { $0.id == t }), list[i].schedule == nil { list[i].state = .failed }
            }
        }
    }

    // MARK: - Tasks from the conversation

    /// The task this turn belongs to, created from the last user message when
    /// the bot starts reporting steps.
    private func touchTask(_ id: String, title: String? = nil, _ change: (inout BotTask) -> Void) {
        var list = tasks[id] ?? []
        let existing = currentTask[id].flatMap { tid in list.firstIndex { $0.id == tid } }
        if let i = existing {
            if list[i].schedule != nil {
                // A routine's run: record its steps on the routine itself.
                change(&list[i])
            } else {
                change(&list[i])
            }
        } else {
            let lastAsk = messages(for: id).last { $0.role == .user }?.text ?? "Task"
            var t = BotTask(botID: id, title: title ?? Self.title(from: lastAsk), prompt: lastAsk,
                            symbol: "circle.dashed", state: .inProgress)
            change(&t)
            list.insert(t, at: 0)
            currentTask[id] = t.id
        }
        tasks[id] = list
        persistTasks(id)
    }

    private func completeTask(_ id: String) {
        guard let tid = currentTask[id] else { return }
        setTasks(id) { list in
            if let i = list.firstIndex(where: { $0.id == tid }) {
                list[i].lastRun = Date()
                if list[i].schedule == nil {
                    list[i].state = .completed
                    list[i].symbol = "checkmark.circle"
                    for s in list[i].steps.indices { list[i].steps[s].done = true }
                }
            }
        }
        currentTask[id] = nil
    }

    static func title(from text: String) -> String {
        let words = text.replacingOccurrences(of: "\n", with: " ").split(separator: " ")
        let head = words.prefix(7).joined(separator: " ")
        return words.count > 7 ? head + "…" : head
    }

    private func setTasks(_ id: String, _ change: (inout [BotTask]) -> Void) {
        var list = tasks[id] ?? []
        change(&list)
        tasks[id] = list
        persistTasks(id)
    }

    private func persistTasks(_ id: String) {
        try? volume.writeJSON(tasks[id] ?? [], VolumeLayout.tasks(id))
        if let bot = bot(id) { onTasksChanged?(bot, tasks[id] ?? []) }
    }

    // MARK: - Mutation helpers

    private func update(_ id: String, _ change: (inout Bot) -> Void) {
        guard let i = bots.firstIndex(where: { $0.id == id }) else { return }
        change(&bots[i])
    }

    private func append(_ m: ChatMessage) {
        messages[m.botID, default: []].append(m)
    }

    // MARK: - Persistence

    /// The bot's home in the Volume: identity, instructions (with its rules),
    /// rules.yaml, and a memory file if it has none yet.
    func writeHome(_ bot: Bot) {
        let r = rules(for: bot.id)
        try? volume.writeJSON(bot, VolumeLayout.identity(bot.id))
        try? volume.writeJSON(r, "agents/\(bot.id)/identity/rules.json")
        try? volume.writeText(VolumeLayout.rules(bot.id), RuleEngine.yaml(r))
        try? volume.writeText(VolumeLayout.instructions(bot.id, harness: bot.harness),
                             BotInstructions.render(bot: bot, rules: r))
        if (try? volume.read(VolumeLayout.memory(bot.id))) == nil {
            try? volume.writeText(VolumeLayout.memory(bot.id), "# What \(bot.name) remembers\n")
        }
    }

    struct RunRecovery: Codable {
        var runID: String
        var cursor: UInt64
        var turn: UInt32?
        var text: String?
        var busy: Bool
        var taskID: String?
    }

    struct Saved: Codable {
        var messages: [String: [ChatMessage]]
        var approvals: [ApprovalRequest]
        var notifications: [BotNotification]
        var bots: [Bot]
        var recovery: [String: RunRecovery]? = nil
        var executions: ExecutionRegistry? = nil
    }

    var stateURL: URL { dataDirectory.appendingPathComponent("state.json") }

    public func save() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        var recovery: [String: RunRecovery] = [:]
        for bot in bots {
            guard let runID = bot.runID else { continue }
            recovery[bot.id] = RunRecovery(
                runID: runID, cursor: cursors[bot.id] ?? 0,
                turn: turnText[bot.id]?.turn, text: turnText[bot.id]?.text,
                busy: busy.contains(bot.id), taskID: currentTask[bot.id])
        }
        let saved = Saved(messages: messages, approvals: approvals, notifications: notifications,
                          bots: bots, recovery: recovery, executions: executions)
        if let data = try? e.encode(saved) { try? data.write(to: stateURL, options: .atomic) }
        for bot in bots { try? volume.writeJSON(bot, VolumeLayout.identity(bot.id)) }
    }

    func load() {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        var runtime: [String: Bot] = [:]
        var recovery: [String: RunRecovery] = [:]
        if let data = try? Data(contentsOf: stateURL), let saved = try? d.decode(Saved.self, from: data) {
            messages = saved.messages
            approvals = saved.approvals
            notifications = saved.notifications
            recovery = saved.recovery ?? [:]
            executions = saved.executions ?? ExecutionRegistry()
            for b in saved.bots { runtime[b.id] = b }
        }
        // The Volume is the source of truth for which bots exist.
        let homes = (try? volume.ls("agents/")) ?? []
        bots = homes.filter(\.isFolder).compactMap { entry in
            let id = String(entry.name)
            guard var bot = try? volume.readJSON(Bot.self, VolumeLayout.identity(id)) else { return nil }
            if let live = runtime[id] { bot.runID = live.runID ?? bot.runID; bot.spaceID = live.spaceID ?? bot.spaceID }
            return bot
        }.sorted { $0.createdAt < $1.createdAt }
        for i in bots.indices where bots[i].executionTargetID == nil {
            do { try executions.migrate(&bots[i]) }
            catch { lastError = "Execution target migration needs attention: \(error)" }
        }
        for bot in bots {
            if bot.mood == .error { failedTurns.insert(bot.id) }
            rules[bot.id] = (try? volume.readJSON([CustomRule].self, "agents/\(bot.id)/identity/rules.json"))
                ?? CustomRule.defaults
            tasks[bot.id] = (try? volume.readJSON([BotTask].self, VolumeLayout.tasks(bot.id))) ?? []
            if let state = recovery[bot.id], state.runID == bot.runID {
                cursors[bot.id] = state.cursor
                if let turn = state.turn, let text = state.text { turnText[bot.id] = (turn, text) }
                if state.busy && !bot.isPaused { busy.insert(bot.id) }
                currentTask[bot.id] = state.taskID
            }
        }
    }
}
