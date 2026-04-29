import AppKit
import SwiftUI

struct DebugCommands: Commands {
    let hemaState: HemaState

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
