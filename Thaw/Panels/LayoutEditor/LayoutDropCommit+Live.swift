//
//  LayoutDropCommit+Live.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit
import MenuBarModel

extension LayoutDropCommit {
    static func commit(_ drop: Drop, appState: AppState, undoManager: UndoManager?, finished: @escaping @MainActor () -> Void) {
        guard drop.source != drop.target else {
            reorder(drop, appState: appState, undoManager: undoManager)
            finished()
            return
        }
        ExplicitLayoutEdit.task {
            await seatAndRecord(drop, appState: appState)
            finished()
        }
    }

    /// The same drop awaited to its end, for a caller that reports the outcome.
    /// Returns false when the move path declined it.
    static func perform(_ drop: Drop, appState: AppState) async -> Bool {
        guard drop.source != drop.target else {
            reorder(drop, appState: appState, undoManager: nil)
            return true
        }
        return await ExplicitLayoutEdit.$isActive.withValue(true) {
            await seatAndRecord(drop, appState: appState)
        }
    }

    private static func reorder(_ drop: Drop, appState: AppState, undoManager: UndoManager?) {
        LayoutBarKeyboard.applySectionOrder(
            drop.targetOrder,
            previousOrder: drop.previousTargetOrder,
            section: drop.target,
            appState: appState,
            undoManager: undoManager,
            actionName: String(localized: "Move \(drop.items.first?.displayName ?? "")")
        )
    }

    /// Seats the items before the assertion flips, as for a move from the item menu, then
    /// records the target's membership and order once. Returns whether the record was made.
    @discardableResult
    private static func seatAndRecord(_ drop: Drop, appState: AppState) async -> Bool {
        let controller = appState.menuBarManager.sectionController
        var recorded = false
        await appState.itemManager.seatItemsForSectionTransition(
            drop.items,
            to: drop.target,
            orderedAs: drop.targetOrder
        ) {
            if let refusal = appState.menuBarManager.setSection(drop.target, items: drop.items, atomically: true) {
                let sourceItems = appState.itemManager.managedItems(for: drop.source)
                appState.layoutFeedback.post(
                    LayoutBarFeedbackCenter.blockedGroupMove(
                        groupName: MenuBarSearchItemActions.groupDisplayName(for: drop.items, in: sourceItems, appState: appState),
                        section: drop.target,
                        refusal: refusal
                    )
                )
                return
            }
            // Overflow and temporary reveals can change presentation without changing assignment.
            guard drop.items.allSatisfy({ controller.authoredSection(for: $0.uniqueIdentifier) == drop.target }) else {
                diagLog.warning("Assignment to \(drop.target.logString) was not confirmed; preserving the stored order")
                if let item = drop.items.first {
                    appState.layoutFeedback.post(LayoutBarFeedbackCenter.itemCannotMove(itemName: item.displayName, section: drop.target))
                }
                return
            }
            if drop.items.count == 1 || drop.isBatch {
                controller.setSectionOrder(from: drop.targetOrder, for: drop.target)
                appState.itemManager.scheduleSectionOrderApply(for: drop.target)
            }
            recorded = true
        }
        await appState.itemManager.cacheItemsRegardless(skipRecentMoveCheck: true)
        return recorded
    }

    private static let diagLog = DiagLog(category: "LayoutDropCommit")
}
