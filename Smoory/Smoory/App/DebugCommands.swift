import AppKit
import SwiftData
import SwiftUI

struct DebugCommands: Commands {
    let hemaState: HemaState
    let modelContainer: ModelContainer
    let scheduledActionService: ScheduledActionService?
    let morningBriefDispatcher: MorningBriefDispatcher?

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Dump hema state") {
                guard case .ready(let hema) = hemaState else {
                    print("[hema] Not ready — cannot dump state.")
                    return
                }
                Task {
                    do {
                        try await hema.dumpStateToConsole()
                    } catch {
                        print("[hema] Dump failed: \(error)")
                    }
                }
            }
            Button("Hema self-test") {
                guard case .ready(let hema) = hemaState else {
                    print("[hema] Not ready — cannot run self-test.")
                    return
                }
                Task {
                    do {
                        let report = try await hema.runSelfTest()
                        for line in report.lines { print(line) }
                    } catch {
                        print("[hema] Self-test failed to run: \(error)")
                    }
                }
            }

            Divider()

            Button("Test Voyage embedding") {
                Task {
                    let embedder = VoyageEmbedder()
                    let start = Date()
                    do {
                        let result = try await embedder.embedWithUsage(["hello world"])
                        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
                        guard let first = result.embeddings.first else {
                            print("[voyage] empty result")
                            return
                        }
                        let tokens = result.totalTokens.map { String($0) } ?? "—"
                        print("---- VOYAGE EMBED TEST ----")
                        print("dimension: \(first.count)")
                        print("first 10: \(Array(first.prefix(10)))")
                        print("latency: \(elapsedMs) ms")
                        print("tokens used: \(tokens)")
                        print("---- END ----")
                    } catch {
                        print("[voyage] error: \(error)")
                    }
                }
            }

            Button("Hema retrieval test") {
                guard case .ready(let hema) = hemaState else {
                    print("[hema] Not ready — cannot run retrieval test.")
                    return
                }
                Task {
                    do {
                        let report = try await hema.runRetrievalTest()
                        for line in report.lines { print(line) }
                    } catch {
                        print("[hema] Retrieval test failed to run: \(error)")
                    }
                }
            }

            Button("Seed test todo with subtasks") {
                let context = ModelContext(modelContainer)
                let saturday = Calendar.current.nextDate(
                    after: Date(),
                    matching: DateComponents(weekday: 7),
                    matchingPolicy: .nextTime
                ) ?? Date().addingTimeInterval(86400 * 3)

                let parent = Todo()
                parent.title = "Plan birthday party"
                parent.dueDate = saturday

                let s1 = Todo()
                s1.title = "Send invitations"
                s1.isCompleted = true
                s1.completedAt = Date()
                s1.parentTodo = parent

                let s2 = Todo()
                s2.title = "Order cake"
                s2.parentTodo = parent

                let s3 = Todo()
                s3.title = "Pick up balloons"
                s3.parentTodo = parent

                context.insert(parent)
                context.insert(s1)
                context.insert(s2)
                context.insert(s3)

                do {
                    try context.save()
                    print("[debug] seeded parent + 3 subtasks (parent id=\(parent.id))")
                } catch {
                    print("[debug] seed failed: \(error)")
                }
            }

            Button("Seed hema with test data") {
                guard case .ready(let hema) = hemaState else {
                    print("[hema] Not ready — cannot seed.")
                    return
                }
                Task {
                    do {
                        let report = try await hema.seedTestData()
                        for line in report.lines { print(line) }
                    } catch {
                        print("[hema] Seed failed: \(error)")
                    }
                }
            }

            Divider()

            Button("Tool registry dump") {
                print("---- TOOL REGISTRY ----")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                for tool in ToolRegistry.allTools {
                    print("name:        \(tool.name)")
                    print("tier:        \(tool.confirmationTier)")
                    print("description: \(tool.description)")
                    if let data = try? encoder.encode(tool.inputSchema),
                       let str = String(data: data, encoding: .utf8) {
                        print("schema:")
                        print(str)
                    }
                    print("---")
                }
                print("---- END ----")
            }

            Divider()

            Divider()

            ScheduledActionDebugCommands(
                service: scheduledActionService,
                modelContainer: modelContainer
            )

            Divider()

            Button("Generate morning brief now") {
                guard case .ready(let hema) = hemaState,
                      let svc = scheduledActionService
                else {
                    print("[debug] hema or service not ready — cannot generate")
                    return
                }
                Task { @MainActor in
                    let generator = MorningBriefGenerator(
                        modelContainer: modelContainer,
                        hema: hema,
                        calendarService: CalendarService(),
                        appGroupWriter: AppGroupContainerWriter(),
                        scheduledActionService: svc
                    )
                    do {
                        let brief = try await generator.generate()
                        print("[debug] generated morning brief")
                        print("  headline: \(brief.headline)")
                        print("  secondaryItems: \(brief.secondaryItems.count)")
                        print("  calendar entries: \(brief.calendar.count)")
                        print("  reflectiveNote: \(brief.reflectiveNote ?? "(none)")")
                        print("  goalNudge: \(brief.goalNudge?.goalTitle ?? "(none)")")
                    } catch {
                        print("[debug] morning brief generation failed: \(error)")
                    }
                }
            }

            Button("Open today's brief JSON") {
                let path = AppGroupContainerWriter()?.morningBriefURL.path(percentEncoded: false)
                guard let path else {
                    print("[debug] App Group container unavailable")
                    return
                }
                let data = try? Data(contentsOf: URL(fileURLWithPath: path))
                guard let data, let str = String(data: data, encoding: .utf8) else {
                    print("[debug] morning-brief.json not found at \(path)")
                    return
                }
                print("---- morning-brief.json (\(path)) ----")
                print(str)
                print("---- END ----")
            }

            Divider()

            Button("Dedupe facts") {
                guard case .ready(let hema) = hemaState else {
                    print("[hema] Not ready — cannot dedupe.")
                    return
                }
                let alert = NSAlert()
                alert.messageText = "Dedupe facts?"
                alert.informativeText = "Merges duplicate facts in hema. Within each duplicate group the surviving fact is the one with user_confirmed = true, then highest confidence, then earliest created_at. The rest are deleted from semantic_facts and the vector index. Continue?"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Dedupe")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                Task {
                    do {
                        let report = try await hema.dedupeFacts()
                        for line in report.lines { print(line) }
                        await MainActor.run {
                            let result = NSAlert()
                            result.messageText = "Dedupe complete"
                            result.informativeText = report.summary
                            result.alertStyle = .informational
                            result.addButton(withTitle: "OK")
                            result.runModal()
                        }
                    } catch {
                        print("[hema] Dedupe failed: \(error)")
                        await MainActor.run {
                            let fail = NSAlert()
                            fail.messageText = "Dedupe failed"
                            fail.informativeText = "\(error)"
                            fail.alertStyle = .critical
                            fail.addButton(withTitle: "OK")
                            fail.runModal()
                        }
                    }
                }
            }

            Button("Reset hema") {
                guard case .ready(let hema) = hemaState else {
                    print("[hema] Not ready — cannot reset.")
                    return
                }
                let alert = NSAlert()
                alert.messageText = "Reset hema?"
                alert.informativeText = "This deletes all hema data. Continue?"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Reset")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                Task {
                    do {
                        try await hema.reset()
                        print("[hema] Reset complete.")
                    } catch {
                        print("[hema] Reset failed: \(error)")
                    }
                }
            }
        }
    }
}
