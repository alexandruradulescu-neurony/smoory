import Foundation
import SwiftData

/// Generates and persists the three compact memory tiers (.today, .recent, .overall)
/// the Orchestrator injects into every chat call. Each tier has its own input
/// window, model tier, and word-count bounds. Privacy is enforced at the data-fetch
/// boundary — `readAllFacts` filters `is_private = 1` rows by default and this
/// generator never overrides that.
///
/// Failure semantics: on LLM error, parse failure, or out-of-bounds word count after
/// retry, the previously-active compact memory of that kind stays active and the
/// failure counter increments. `replaceActiveCompactMemory` is only called after a
/// body passes validation.
@MainActor
final class CompactMemoryGenerator {
    private let modelContainer: ModelContainer
    private let hema: HemaService
    private let calendarService: CalendarService
    private let client: LLMClient

    init(
        modelContainer: ModelContainer,
        hema: HemaService,
        calendarService: CalendarService,
        client: LLMClient = RoutingLLMClient()
    ) {
        self.modelContainer = modelContainer
        self.hema = hema
        self.calendarService = calendarService
        self.client = client
    }

    // MARK: - Word-count bounds

    /// `± 25%` softening of the spec's nominal ranges so first-attempt prose isn't
    /// rejected for tiny over/under counts. Anything wildly off triggers retry.
    private static func wordCountBounds(for kind: CompactMemory.Kind) -> ClosedRange<Int> {
        switch kind {
        case .today: 60...250        // nominal 80-200
        case .recent: 120...360      // nominal 150-300
        case .overall: 240...600     // nominal 300-500
        }
    }

    /// The retry-prompt's target range — uses the nominal spec range to nudge the
    /// LLM back into bounds without telegraphing the validator's softer cutoffs.
    private static func nominalRange(for kind: CompactMemory.Kind) -> (Int, Int) {
        switch kind {
        case .today: (80, 200)
        case .recent: (150, 300)
        case .overall: (300, 500)
        }
    }

    // MARK: - Public API

    /// Persists the .today compact memory body produced by the morning brief's
    /// LLM call. NO additional LLM call — pure persistence path. Validates
    /// word count and rejects (without retry) if outside bounds; the brief's
    /// own retry path already gives the LLM a second attempt.
    @discardableResult
    func writeTodayFromBrief(body: String, generatedAt: Date) async throws -> CompactMemory {
        let normalized = normalizeBody(body)
        let words = wordCount(normalized)
        try validate(body: normalized, wordCount: words, kind: .today)
        let memory = CompactMemory(
            id: UUID(),
            kind: .today,
            body: normalized,
            wordCount: words,
            generatedAt: generatedAt,
            supersededAt: nil,
            generatingModel: AIProviderStore.current().modelID(for: .balanced)
        )
        try await hema.replaceActiveCompactMemory(memory)
        return memory
    }

    /// Independent regeneration path for .today. Uses .balanced tier.
    /// Used by the Debug command and as a fallback when the morning brief
    /// route didn't produce a compact memory.
    @discardableResult
    func generateToday(now: Date = Date()) async throws -> CompactMemory {
        let inputs = try await collectTodayInputs(now: now)
        let body = try await runRegeneration(
            kind: .today,
            tier: .balanced,
            systemPrompt: CompactMemoryPrompts.todaySystemPrompt,
            userMessage: CompactMemoryPrompts.todayUserMessage(inputs)
        )
        return try await persist(body: body, kind: .today, tier: .balanced, generatedAt: now)
    }

    /// Heavy-tier regeneration. Triggered after every week review.
    @discardableResult
    func generateRecent(now: Date = Date()) async throws -> CompactMemory {
        let inputs = try await collectRecentInputs(now: now)
        let body = try await runRegeneration(
            kind: .recent,
            tier: .heavy,
            systemPrompt: CompactMemoryPrompts.recentSystemPrompt,
            userMessage: CompactMemoryPrompts.recentUserMessage(inputs)
        )
        return try await persist(body: body, kind: .recent, tier: .heavy, generatedAt: now)
    }

    /// Heavy-tier regeneration. Triggered every 4th completed week review.
    @discardableResult
    func generateOverall(now: Date = Date()) async throws -> CompactMemory {
        let inputs = try await collectOverallInputs(now: now)
        let body = try await runRegeneration(
            kind: .overall,
            tier: .heavy,
            systemPrompt: CompactMemoryPrompts.overallSystemPrompt,
            userMessage: CompactMemoryPrompts.overallUserMessage(inputs)
        )
        return try await persist(body: body, kind: .overall, tier: .heavy, generatedAt: now)
    }

    // MARK: - Regeneration core

    /// Two-attempt pattern (mirrors MorningBriefGenerator). First attempt with the
    /// strict prompt. On any failure (empty, JSON, out-of-bounds), retries once
    /// with the prompt + retry addendum. If both fail, increments the failure
    /// counter and throws — the previously-active compact memory of that kind
    /// stays active.
    private func runRegeneration(
        kind: CompactMemory.Kind,
        tier: ModelTier,
        systemPrompt: String,
        userMessage: String
    ) async throws -> String {
        // First attempt — strict prompt.
        do {
            let body = try await callLLM(tier: tier, systemPrompt: systemPrompt, userMessage: userMessage)
            let words = wordCount(body)
            try validate(body: body, wordCount: words, kind: kind)
            return body
        } catch {
            print("[compact] .\(kind.rawValue) first attempt failed: \(error). Retrying with stricter prompt.")
            CompactMemoryFailureCounter.shared.increment()
        }

        // Retry — same inputs, prompt augmented with explicit bounds.
        let nominal = Self.nominalRange(for: kind)
        let retryPrompt = systemPrompt + "\n\n" + CompactMemoryPrompts.retryAddendum(targetMin: nominal.0, targetMax: nominal.1)
        do {
            let body = try await callLLM(tier: tier, systemPrompt: retryPrompt, userMessage: userMessage)
            let words = wordCount(body)
            try validate(body: body, wordCount: words, kind: kind)
            return body
        } catch {
            CompactMemoryFailureCounter.shared.increment()
            throw CompactMemoryError.retryFailed(underlying: error)
        }
    }

    private func callLLM(tier: ModelTier, systemPrompt: String, userMessage: String) async throws -> String {
        let response = try await client.complete(
            model: tier,
            systemPrompt: systemPrompt,
            messages: [LLMMessage(role: .user, text: userMessage)],
            tools: nil
        )
        return normalizeBody(response.text)
    }

    private func validate(body: String, wordCount words: Int, kind: CompactMemory.Kind) throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw CompactMemoryError.llmReturnedEmpty }
        // Reject obvious JSON or fenced output. The compact memory must be
        // consumable by the chat system prompt as-is.
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || trimmed.hasPrefix("```") {
            throw CompactMemoryError.llmReturnedJSON
        }
        let bounds = Self.wordCountBounds(for: kind)
        if !bounds.contains(words) {
            throw CompactMemoryError.wordCountOutOfBounds(actual: words, expected: bounds)
        }
    }

    private func persist(body: String, kind: CompactMemory.Kind, tier: ModelTier, generatedAt: Date) async throws -> CompactMemory {
        let normalized = normalizeBody(body)
        let words = wordCount(normalized)
        let memory = CompactMemory(
            id: UUID(),
            kind: kind,
            body: normalized,
            wordCount: words,
            generatedAt: generatedAt,
            supersededAt: nil,
            generatingModel: AIProviderStore.current().modelID(for: tier)
        )
        try await hema.replaceActiveCompactMemory(memory)
        return memory
    }

    // MARK: - Input collection

    private func collectTodayInputs(now: Date) async throws -> CompactMemoryPrompts.TodayInputs {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)

        // Calendar events for today.
        let events: [CalendarEvent]
        do {
            let window = try await calendarService.eventsForCurrentWindow(now: now)
            let today = window.days.first { cal.isDate($0.date, inSameDayAs: startOfToday) }
            events = today?.events ?? []
        } catch {
            print("[compact] .today: calendar fetch failed (\(error)) — proceeding without events")
            events = []
        }

        // Todos completed today (4.8c — backing entity is UserListItem). Predicate
        // filters at the row level identically to the pre-4.8c Todo query.
        let todoContext = ModelContext(modelContainer)
        let allCompletedDescriptor = FetchDescriptor<UserListItem>(
            predicate: #Predicate<UserListItem> {
                $0.isCompleted == true && $0.isArchived == false && $0.parentItem == nil
            }
        )
        let allCompleted = (try? todoContext.fetch(allCompletedDescriptor)) ?? []
        let completedToday = allCompleted.filter {
            ($0.completedAt ?? .distantPast) >= startOfToday
        }

        // Memory turns for today. If >50, take 30 most recent + 20 oldest in
        // chronological order; preserves morning context + most recent state and
        // drops middle-of-day repetition. Documented: this is an intentional
        // input shaping — middle turns are silently omitted to fit context.
        let turnsRaw = try await hema.readAllTurns(limit: 1000, since: startOfToday)
        // readAllTurns sorts created_at DESC; rebuild chronological order.
        let chronological = turnsRaw.reversed()
        let turns: [MemoryTurn]
        if chronological.count > 50 {
            let chronologicalArr = Array(chronological)
            let oldest20 = Array(chronologicalArr.prefix(20))
            let mostRecent30 = Array(chronologicalArr.suffix(30))
            turns = oldest20 + mostRecent30
        } else {
            turns = Array(chronological)
        }

        let previousTodayBody = try await fetchPreviousActive(kind: .today)?.body

        return CompactMemoryPrompts.TodayInputs(
            now: now,
            calendarEvents: events,
            completedTodosTodayTitles: completedToday.map { $0.text },
            memoryTurns: turns,
            previousTodayBody: previousTodayBody
        )
    }

    private func collectRecentInputs(now: Date) async throws -> CompactMemoryPrompts.RecentInputs {
        let cal = Calendar.current
        let thirtyDaysAgo = cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: now)) ?? now

        // Last-30d facts, non-private (default), non-superseded (default), expired included.
        let filter = FactFilter(
            tags: nil, entities: nil,
            includeExpired: true,
            includeSuperseded: false,
            includePrivate: false,    // EXPLICIT — never flip this
            minConfidence: nil,
            createdSince: thirtyDaysAgo,
            createdBefore: nil
        )
        let facts = try await hema.readAllFacts(filter: filter, limit: 200, offset: 0)

        let prevRecent = try await fetchPreviousActive(kind: .recent)?.body
        let prevOverall = try await fetchPreviousActive(kind: .overall)?.body

        return CompactMemoryPrompts.RecentInputs(
            now: now,
            facts: facts,
            previousRecentBody: prevRecent,
            previousOverallBody: prevOverall
        )
    }

    private func collectOverallInputs(now: Date) async throws -> CompactMemoryPrompts.OverallInputs {
        // All-time user-confirmed facts. SwiftData's #Predicate doesn't filter
        // user_confirmed at the SQL layer here (we pull from hema, not SwiftData),
        // so fetch with private/superseded filters then filter user_confirmed in Swift.
        let filter = FactFilter(
            tags: nil, entities: nil,
            includeExpired: true,
            includeSuperseded: false,
            includePrivate: false,    // EXPLICIT — never flip this
            minConfidence: nil,
            createdSince: nil,
            createdBefore: nil
        )
        let allEligible = try await hema.readAllFacts(filter: filter, limit: 1000, offset: 0)
        let userConfirmed = allEligible.filter { $0.userConfirmed }
            .prefix(500)
            .map { $0 }

        let prevOverall = try await fetchPreviousActive(kind: .overall)?.body
        let prevRecent = try await fetchPreviousActive(kind: .recent)?.body

        return CompactMemoryPrompts.OverallInputs(
            now: now,
            facts: userConfirmed,
            previousOverallBody: prevOverall,
            previousRecentBody: prevRecent
        )
    }

    private func fetchPreviousActive(kind: CompactMemory.Kind) async throws -> CompactMemory? {
        let actives = try await hema.readActiveCompactMemories()
        return actives.first { $0.kind == kind }
    }

    // MARK: - Helpers

    private func normalizeBody(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func wordCount(_ s: String) -> Int {
        s.split { $0.isWhitespace || $0.isNewline }.count
    }
}
