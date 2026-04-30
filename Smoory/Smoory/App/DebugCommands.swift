import AppKit
import SwiftData
import SwiftUI

struct DebugCommands: Commands {
    let hemaState: HemaState
    let modelContainer: ModelContainer
    let scheduledActionService: ScheduledActionService?

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
