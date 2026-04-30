import Foundation
import SwiftData

@Model
final class CaptureItem {
    var id: UUID = UUID()
    var kind: CaptureKind = CaptureKind.text
    var content: String = ""
    var filePath: String?
    var extractedText: String?
    var source: CaptureSource = CaptureSource.quickAdd
    var processed: Bool = false
    var triageOutcome: String?
    var linkedTo: [CaptureLink] = []
    var pinnedToProject: Project?      // inverse of Project.notes — see DECISIONS.md decision 10
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init() {}
}
