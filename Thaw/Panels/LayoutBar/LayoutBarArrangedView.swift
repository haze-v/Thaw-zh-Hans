//
//  LayoutBarArrangedView.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa

/// Shared base class for draggable views inside the layout bar editor.
class LayoutBarArrangedView: NSView {
    enum Kind {
        case item(MenuBarItem)
        case opaqueSlot(LayoutOpaqueSlotDescriptor)
        case newItemsBadge
        /// Expand collapsed groups before persistence; index translation and layoutItemsForPersistence assume one view per item.
        case collapsedGroup(members: [MenuBarItem])
    }

    /// Capture the origin and the group before any destination changes the view tree.
    private(set) weak var dragOrigin: LayoutBarContainer?
    private var draggedSiblings: [LayoutBarArrangedView] = []

    private var draggedItemIndex = 0

    var draggedViews: [LayoutBarArrangedView] {
        var members = draggedSiblings
        members.insert(self, at: draggedItemIndex)
        return members
    }

    func captureDragOrigin(in container: LayoutBarContainer) {
        guard dragOrigin == nil else { return }
        let unit = container.dragUnitViews(for: self)
        dragOrigin = container
        draggedSiblings = unit.filter { $0 !== self }
        draggedItemIndex = unit.firstIndex(of: self) ?? 0
    }

    var hasContainer = false

    var isEnabled = true {
        didSet {
            needsDisplay = true
        }
    }

    var isDraggingPlaceholder = false {
        didSet {
            needsDisplay = true
        }
    }

    /// The average color info of the menu bar, used for adaptive coloring.
    var averageColorInfo: MenuBarAverageColorInfo? {
        didSet {
            needsDisplay = true
        }
    }

    var kind: Kind {
        fatalError("Subclasses must override kind")
    }

    var isNewItemsBadge: Bool {
        if case .newItemsBadge = kind {
            return true
        }
        return false
    }

    func draggingImage() -> NSImage? {
        nil
    }
}

// MARK: LayoutBarArrangedView: NSDraggingSource

extension LayoutBarArrangedView: NSDraggingSource {
    func draggingSession(_: NSDraggingSession, sourceOperationMaskFor _: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt _: NSPoint) {
        let container = superview as? LayoutBarContainer
        container?.acceptsViewUpdates = false
        if let container {
            captureDragOrigin(in: container)
        }

        session.animatesToStartingPositionsOnCancelOrFail = false

        isDraggingPlaceholder = true
    }

    func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation: NSDragOperation) {
        isDraggingPlaceholder = false
        if operation.isEmpty {
            (superview as? LayoutBarContainer)?.acceptsViewUpdates = true
            dragOrigin?.acceptsViewUpdates = true
        }
        dragOrigin = nil
        draggedSiblings = []
        draggedItemIndex = 0
    }
}

extension LayoutBarArrangedView: @MainActor NSAccessibilityLayoutItem {}
