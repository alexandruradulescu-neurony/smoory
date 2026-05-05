import Foundation

/// Result of one full Reminders.app reconcile pass. Built incrementally by
/// `RemindersSyncService.performReconcile()`, surfaced to the UI via the "Sync now"
/// flow and to the console for debugging.
struct ReconcileReport: Sendable {
    let listsImportedFromEK: Int       // EK calendars new to Smoory this pass
    let listsPushedToEK: Int           // Smoory lists that had no EK pair, now created in EK
    let listsRenamed: Int              // titles propagated either direction
    let itemsImportedFromEK: Int       // EK reminders new to Smoory
    let itemsPushedToEK: Int           // Smoory items new to EK
    let itemsUpdated: Int              // text/completion changes propagated either direction
    let itemsDeletedSmoorySide: Int    // EK reminder gone → Smoory item removed
    let errors: [String]
    let durationSeconds: Double

    static let empty = ReconcileReport(
        listsImportedFromEK: 0,
        listsPushedToEK: 0,
        listsRenamed: 0,
        itemsImportedFromEK: 0,
        itemsPushedToEK: 0,
        itemsUpdated: 0,
        itemsDeletedSmoorySide: 0,
        errors: [],
        durationSeconds: 0
    )

    var isNoOp: Bool {
        listsImportedFromEK == 0
            && listsPushedToEK == 0
            && listsRenamed == 0
            && itemsImportedFromEK == 0
            && itemsPushedToEK == 0
            && itemsUpdated == 0
            && itemsDeletedSmoorySide == 0
    }

    var summary: String {
        if isNoOp { return "Already in sync." }
        var parts: [String] = []
        if listsImportedFromEK > 0 { parts.append("imported \(listsImportedFromEK) list(s)") }
        if listsPushedToEK > 0 { parts.append("pushed \(listsPushedToEK) list(s) to Reminders") }
        if listsRenamed > 0 { parts.append("renamed \(listsRenamed) list(s)") }
        if itemsImportedFromEK > 0 { parts.append("imported \(itemsImportedFromEK) item(s)") }
        if itemsPushedToEK > 0 { parts.append("pushed \(itemsPushedToEK) item(s)") }
        if itemsUpdated > 0 { parts.append("updated \(itemsUpdated) item(s)") }
        if itemsDeletedSmoorySide > 0 { parts.append("removed \(itemsDeletedSmoorySide) item(s) deleted in Reminders") }
        return parts.joined(separator: ", ").capitalized + "."
    }
}

/// Mutable accumulator used during a reconcile pass. Built once per `performReconcile()`
/// call and frozen into a `ReconcileReport` at the end.
struct ReconcileReportBuilder {
    var listsImportedFromEK = 0
    var listsPushedToEK = 0
    var listsRenamed = 0
    var itemsImportedFromEK = 0
    var itemsPushedToEK = 0
    var itemsUpdated = 0
    var itemsDeletedSmoorySide = 0
    var errors: [String] = []

    func build(durationSeconds: Double) -> ReconcileReport {
        ReconcileReport(
            listsImportedFromEK: listsImportedFromEK,
            listsPushedToEK: listsPushedToEK,
            listsRenamed: listsRenamed,
            itemsImportedFromEK: itemsImportedFromEK,
            itemsPushedToEK: itemsPushedToEK,
            itemsUpdated: itemsUpdated,
            itemsDeletedSmoorySide: itemsDeletedSmoorySide,
            errors: errors,
            durationSeconds: durationSeconds
        )
    }
}
