//
//  LayoutBarPaddingView.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AsyncAlgorithms
import Cocoa
import Combine
import MenuBarModel

/// A Cocoa view that manages the menu bar layout interface.
final class LayoutBarPaddingView: NSView {
    private static let diagLog = DiagLog(category: "LayoutBarPaddingView")

    private let container: LayoutBarContainer
    private var isStabilizing = false

    private var notchView: NotchIndicatorView?
    private var notchWidthConstraint: NSLayoutConstraint?
    private var notchTrailingConstraint: NSLayoutConstraint?
    private var minWidthConstraint: NSLayoutConstraint?
    private var containerLeadingAfterNotchConstraint: NSLayoutConstraint?
    private var containerLeadingInsetConstraint: NSLayoutConstraint?
    private var notchObservers = Set<AnyCancellable>()

    /// Whether an item may be used as a layout-bar drag source on macOS 27.
    /// The visible Thaw control is a real movable status item; the zero-width
    /// divider controls remain structural and must never be reordered.
    static func acceptsLayoutDrag(of item: MenuBarItem) -> Bool {
        !item.isControlItem || item.tag.matchesVisibleControlItem
    }

    /// Whether anchored Apple system items may be freely reordered in the
    /// layout editor. Without Thaw Bar, hidden anchored items still mirror the
    /// real menu bar's trailing system-control placement.
    static func allowsAnchoredSystemItemReordering(appState: AppState?) -> Bool {
        guard let appState else {
            return false
        }
        if let displayID = appState.itemManager.itemDisplayID {
            return appState.settings.displaySettings.useThawBar(for: displayID)
        }
        return appState.settings.displaySettings.configurationForActiveDisplay().useThawBar
    }

    private static func anchoredSystemItemsTrail(in items: [MenuBarItem]) -> [MenuBarItem] {
        MenuBarBackendProvider.current.anchoredSystemItemsTrail(in: items)
    }

    /// Explains a refused drop rather than letting the item snap back in
    /// silence.
    ///
    /// The common case is an Apple item (often Weather) refused because the
    /// system item hiding switch, which sits below the editor, is off.
    ///
    /// Asking again with the switch flipped separates the two cases: if the
    /// assignment would then be allowed, the message names the setting;
    /// otherwise it says the item stays put.
    private func postAssignmentRefusal(
        for item: MenuBarItem,
        to section: MenuBarSection.Name,
        experimentalSystemItemHiding: Bool
    ) {
        guard let appState = container.appState else { return }

        let wouldBeAllowedWithSystemItemHiding = !experimentalSystemItemHiding
            && MenuBarBackendProvider.current.canAssign(
                item,
                to: section,
                experimentalSystemItemHiding: true
            )

        appState.layoutFeedback.post(
            wouldBeAllowedWithSystemItemHiding
                ? LayoutBarFeedbackCenter.systemItemHidingDisabled(
                    itemName: item.displayName,
                    section: section
                )
                : LayoutBarFeedbackCenter.itemCannotMove(
                    itemName: item.displayName,
                    section: section
                )
        )
    }

    private func layoutWatchdogDuration() -> Duration {
        MenuBarItemManager.layoutWatchdogTimeout
    }

    /// The layout view's arranged views.
    var arrangedViews: [LayoutBarArrangedView] {
        get { container.arrangedViews }
        set { container.arrangedViews = newValue }
    }

    /// Creates a layout bar view with the given app state, section, and spacing.
    ///
    /// - Parameters:
    ///   - appState: The shared app state instance.
    ///   - section: The section whose items are represented.
    init(appState: AppState, section: MenuBarSection.Name) {
        self.container = LayoutBarContainer(appState: appState, section: section)

        super.init(frame: .zero)

        addSubview(container)
        self.translatesAutoresizingMaskIntoConstraints = false

        let leadingInsetConstraint = leadingAnchor.constraint(lessThanOrEqualTo: container.leadingAnchor, constant: -7.5)
        self.containerLeadingInsetConstraint = leadingInsetConstraint

        NSLayoutConstraint.activate([
            container.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 7.5),
            leadingInsetConstraint,
        ])

        registerForDraggedTypes([.layoutBarItem, .layoutBarGroupHandle])

        configureNotchObservers(appState: appState)
        updateNotchPresentation()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isStabilizing else { return [] }
        if let handle = sender.draggingSource as? LayoutBarGroupHandleView {
            // The whole-group drop mutates order/assignment on drop rather than
            // reordering arranged views mid-drag, so there is nothing to
            // preview, but the drop can still be refused, and discovering that
            // only on release means the drag just springs back with no cue.
            return groupDropOperation(for: handle, at: sender.draggingLocation)
        }
        // Freeze the destination's arrangedViews so that the cache refresh
        // triggered while the system move is in flight cannot overwrite the
        // mid-drag visual state. updateNewItemsPlacement at the end of move()
        // depends on that state to capture the badge's new neighbors; without
        // this guard the dropped item bounces to the wrong side of the badge.
        let operation = container.handleDrag(sender, phase: .entered)
        if !operation.isEmpty {
            container.acceptsViewUpdates = false
        }
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        container.groupDropMarkerX = nil
        guard !isStabilizing else { return }
        if let sender {
            container.handleDrag(sender, phase: .exited)
        }
        if (sender?.draggingSource as? LayoutBarArrangedView)?.dragOrigin !== container {
            container.acceptsViewUpdates = true
        }
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isStabilizing else { return [] }
        if let handle = sender.draggingSource as? LayoutBarGroupHandleView {
            return groupDropOperation(for: handle, at: sender.draggingLocation)
        }
        let operation = container.handleDrag(sender, phase: .updated)
        if !operation.isEmpty {
            container.acceptsViewUpdates = false
        }
        return operation
    }

    /// Whether a group carried by handle may be dropped into this container's
    /// section, so the cursor shows "no drop" while the drag is still in flight
    /// instead of the user finding out on release.
    ///
    /// A same-section drop is a reorder and never changes membership, so it is
    /// always permitted.
    private func groupDropOperation(for handle: LayoutBarGroupHandleView, at location: NSPoint) -> NSDragOperation {
        guard let appState = container.appState else { return [] }
        let sourceItems = handle.sourceSection == container.section
            ? orderedLayoutItems()
            : appState.itemManager.managedItems(for: handle.sourceSection)
        let members = handle.memberIdentifiers.compactMap { identifier in
            sourceItems.first { $0.uniqueIdentifier == identifier }
        }
        guard members.count >= 2, members.count == handle.memberIdentifiers.count else {
            container.groupDropMarkerX = nil
            return []
        }
        if handle.sourceSection == container.section {
            container.showGroupDropMarker(at: location)
            return .move
        }
        let canMove = MenuBarBackendProvider.current.canMoveGroup(
            members: members,
            expectedMemberCount: handle.memberIdentifiers.count,
            to: container.section,
            experimentalSystemItemHiding: appState.settings.advanced.enableExperimentalSystemItemHiding,
            isHidingAvailable: appState.menuBarManager.sectionController.isHidingAvailable
        )
        return canMove ? .move : []
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        container.groupDropMarkerX = nil
        guard !isStabilizing else { return }
        container.handleDrag(sender, phase: .ended)
        restoreArrangedViewsAfterDrag(from: sender)
    }

    /// Re-enables cache-driven layout updates when a drag ends without a
    /// successful drop (cancelled or rejected). performDragOperation (or the
    /// async move() task it spawns) resets the flag on success; without
    /// this, a cancelled drag leaves every container frozen and the bars stop
    /// accepting moves. Also runs after successful drops (draggingEnded
    /// fires unconditionally), so finishDrag must stay idempotent.
    private func restoreArrangedViewsAfterDrag(from draggingInfo: NSDraggingInfo) {
        guard let draggingSource = draggingInfo.draggingSource as? LayoutBarArrangedView else {
            container.acceptsViewUpdates = true
            return
        }
        finishDrag(sourceContainer: draggingSource.dragOrigin)
    }

    /// Rebuilds the bars from the model once the drop completes or is cancelled.
    private func finishDrag(sourceContainer: LayoutBarContainer?) {
        container.acceptsViewUpdates = true
        if sourceContainer !== container {
            sourceContainer?.acceptsViewUpdates = true
        }
    }

    /// The first hide teaches itself: a drop that carries an item out of the
    /// visible section retires the layout hint and, the first time only,
    /// confirms with the HUD after the assignment is recorded.
    private func noteDropIntoHiddenSection(from sourceSection: MenuBarSection.Name) {
        guard sourceSection != container.section,
              container.section == .hidden || container.section == .alwaysHidden
        else {
            return
        }
        FirstRunHintStore.shared.dismiss(.hideByDrag)
        FirstRunHintStore.shared.markFirstHide()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !isStabilizing else { return false }
        // A drop is the user arranging in Layout, the one move Manual allows.
        return ExplicitLayoutEdit.perform { performLayoutDrop(sender) }
    }

    private func performLayoutDrop(_ sender: NSDraggingInfo) -> Bool {
        if let handle = sender.draggingSource as? LayoutBarGroupHandleView {
            return performGroupHandleDrop(handle, sender: sender)
        }

        guard let draggingSource = sender.draggingSource as? LayoutBarArrangedView else {
            container.acceptsViewUpdates = true
            return false
        }

        let sourceContainer = draggingSource.dragOrigin
        var cleanupDeferredToMoveTask = false
        defer {
            if !cleanupDeferredToMoveTask {
                finishDrag(sourceContainer: sourceContainer)
            }
        }

        if case let .item(draggingItem) = draggingSource.kind,
           draggingItem.tag.matchesVisibleControlItem,
           container.section != .visible
        {
            container.appState?.layoutFeedback.post(
                LayoutBarFeedbackCenter.Refusal(
                    title: String(
                        localized: "“\(Constants.displayName)” couldn’t move to \(MenuBarSection.Name.visible.localizedName)",
                        comment: "Title shown when the Thaw control icon is dropped outside the Visible section"
                    ),
                    message: String(
                        localized: "The \(Constants.displayName) icon has to stay in Visible.",
                        comment: "Explanation shown when the Thaw control icon is dropped outside the Visible section"
                    )
                )
            )

            // Revert the visual state: remove the item from the container it was dropped into
            // and set hasContainer to false so it snaps back to its original container.
            container.handleDrag(sender, phase: .exited)
            draggingSource.hasContainer = false

            return false
        }

        if draggingSource.isNewItemsBadge {
            guard arrangedViews.contains(draggingSource) else { return false }
            container.appState?.itemManager.updateNewItemsPlacement(
                section: container.section,
                arrangedViews: arrangedViews
            )
            sourceContainer?.rebuildViews()
            if sourceContainer !== container {
                container.rebuildViews()
            }
            return true
        }

        guard case let .item(item) = draggingSource.kind,
              Self.acceptsLayoutDrag(of: item)
        else {
            return false
        }

        guard let sourceContainer else { return false }
        let controller = container.appState?.menuBarManager.sectionController
        let sourceSection = sourceContainer.section
        let orderedItems = orderedLayoutItemsForSectionOrder()
        let experimentalSystemItemHiding = container.appState?.settings.advanced.enableExperimentalSystemItemHiding ?? false
        let physicalOrderExperimentalSystemItemHiding = experimentalSystemItemHiding &&
            Self.allowsAnchoredSystemItemReordering(appState: container.appState)

        guard container.admitsDrag(of: draggingSource), arrangedViews.contains(draggingSource) else {
            postAssignmentRefusal(for: item, to: container.section, experimentalSystemItemHiding: experimentalSystemItemHiding)
            return false
        }

        if sourceSection != container.section {
            guard let appState = container.appState else { return false }
            let members = crossSectionGroupMembers(for: item, sourceSection: sourceSection, controller: controller) ?? [item]
            let targetIDs = Set(orderedItems.map(\.uniqueIdentifier))
            guard members.allSatisfy({ targetIDs.contains($0.uniqueIdentifier) }) else {
                postAssignmentRefusal(for: item, to: container.section, experimentalSystemItemHiding: experimentalSystemItemHiding)
                return false
            }
            let drop = LayoutDropCommit.Drop(
                items: members,
                source: sourceSection,
                target: container.section,
                previousTargetOrder: [],
                targetOrder: orderedItems,
                isBatch: members.count > 1
            )
            guard !LayoutDropCommit.refuses(drop, appState: appState) else { return false }
            cleanupDeferredToMoveTask = true
            isStabilizing = true
            Task { @MainActor in
                defer {
                    isStabilizing = false
                    finishDrag(sourceContainer: sourceContainer)
                }
                if await LayoutDropCommit.perform(drop, appState: appState) {
                    noteDropIntoHiddenSection(from: sourceSection)
                }
            }
            return true
        }

        if let index = arrangedViews.firstIndex(of: draggingSource) {
            if sectionIsPhysicallyLive(container.section, controller: controller),
               item.isPhysicallyOrderable(experimentalSystemItemHiding: physicalOrderExperimentalSystemItemHiding)
            {
                if container.section == .visible,
                   let appState = container.appState
                {
                    // Concealed occupants of visible slots (parked
                    // hiding-unsupported apps) are not draggable anchors;
                    // planning against them strands the move.
                    // A hidden Thaw icon has no tile, so it is absent from the
                    // desired order; the planner refuses a live set it cannot order.
                    let desiredIDs = orderedItems.map(\.uniqueIdentifier)
                    let liveItems = appState.itemManager.managedItems(for: .visible)
                        .filter { $0.isOnScreen && !$0.bounds.isEmpty }
                        .filter { !$0.tag.matchesVisibleControlItem || desiredIDs.contains($0.uniqueIdentifier) }
                    let achievableItems = MenuBarLayoutPlannerProvider.current.achievableOrderSegments(
                        items: liveItems,
                        desiredOrder: desiredIDs,
                        experimentalSystemItemHiding: physicalOrderExperimentalSystemItemHiding
                    ).flatMap(\.self)

                    let destination = MenuBarLayoutPlannerProvider.current.achievableDestination(
                        items: liveItems,
                        item: item,
                        desiredOrder: desiredIDs,
                        experimentalSystemItemHiding: physicalOrderExperimentalSystemItemHiding
                    ) ?? visibleThawControlNeighborDestination(
                        for: item,
                        at: index,
                        experimentalSystemItemHiding: physicalOrderExperimentalSystemItemHiding
                    )

                    if let destination {
                        cleanupDeferredToMoveTask = true
                        move(
                            item: item,
                            to: destination,
                            sourceContainer: sourceContainer,
                            sectionOrderToCommit: orderedItems,
                            anchorFallbacks: anchorFallbackChain(
                                for: destination,
                                moving: item,
                                planningItems: liveItems,
                                experimentalSystemItemHiding: physicalOrderExperimentalSystemItemHiding
                            )
                        )
                    } else {
                        // The requested order is either already live or would
                        // cross a fixed anchor. Persist only its achievable
                        // projection so reconciliation cannot retry forever.
                        Self.diagLog.info(
                            """
                            Reorder of \(item.logString) has no achievable destination; \
                            desired=\(desiredIDs) live=\(MenuBarLayoutPlannerProvider.current.orderDescription(liveItems))
                            """
                        )
                        // Merged into the saved order so live items that are off
                        // screen keep their slots instead of dropping out of it.
                        let committed = LayoutEditorOrder.itemsMergingAchievableOrder(
                            achievableItems.map(\.uniqueIdentifier),
                            into: controller?.sectionItemOrder[.visible] ?? [],
                            candidates: appState.itemManager.managedItems(for: .visible)
                        )
                        controller?.setSectionOrder(from: committed, for: .visible)
                        Task { await appState.itemManager.cacheItemsRegardless(skipRecentMoveCheck: true) }
                    }
                    return true
                }

                let destination: MenuBarItemManager.MoveDestination? =
                    if let target = nearestItem(
                        toRightOf: index,
                        requiringMovable: true,
                        experimentalSystemItemHiding: physicalOrderExperimentalSystemItemHiding
                    ) {
                        .leftOfItem(target)
                    } else if let target = nearestItem(
                        toLeftOf: index,
                        requiringMovable: true,
                        experimentalSystemItemHiding: physicalOrderExperimentalSystemItemHiding
                    ) {
                        .rightOfItem(target)
                    } else {
                        nil
                    }
                if let destination {
                    cleanupDeferredToMoveTask = true
                    move(
                        item: item,
                        to: destination,
                        sourceContainer: sourceContainer,
                        sectionOrderToCommit: orderedItems,
                        anchorFallbacks: anchorFallbackChain(
                            for: destination,
                            moving: item,
                            planningItems: orderedItems,
                            experimentalSystemItemHiding: physicalOrderExperimentalSystemItemHiding
                        )
                    )
                    return true
                }
            }

            // Non-live sections record intent, not a completed move. Visible
            // intent needs an explicit apply; concealed sections wait for reveal.
            LayoutDropCommit.recordIntent(of: item, orderedAs: orderedItems, from: sourceSection, to: container.section, controller: controller)

            if let appState = container.appState {
                appState.itemManager.scheduleSectionOrderApply(for: container.section)
                Task { await appState.itemManager.cacheItemsRegardless(skipRecentMoveCheck: true) }
            }
            return true
        }

        return false
    }

    /// The drop-time fallback chain for a planned move: an orderable neighbour
    /// on the same side of the anchor as the requested slot. Captured here, while
    /// the drop's arrangement is still the truth, because the whole premise of
    /// the chain is that the live scan may no longer be trustworthy by the
    /// time the move runs.
    private func anchorFallbackChain(
        for destination: MenuBarItemManager.MoveDestination,
        moving item: MenuBarItem,
        planningItems: [MenuBarItem],
        experimentalSystemItemHiding: Bool
    ) -> [MenuBarItemManager.MoveDestination] {
        let anchor = destination.targetItem
        // Left-to-right regardless of the enumeration's native direction: the
        // neighbour entries below name a slot by the edge it is read from.
        let ordered = MenuBarItem.sortByLeadingEdge(planningItems).filter { $0.uniqueIdentifier != item.uniqueIdentifier }
        guard let anchorIndex = ordered.firstIndex(where: {
            $0.uniqueIdentifier == anchor.uniqueIdentifier
        }) else {
            return []
        }

        var chain: [MenuBarItemManager.MoveDestination] = []

        switch destination {
        case .leftOfItem:
            if let left = ordered[..<anchorIndex].last(where: {
                Self.isUsableAnchor($0, experimentalSystemItemHiding: experimentalSystemItemHiding)
            }) {
                chain.append(.rightOfItem(left))
            }
        case .rightOfItem:
            if anchorIndex + 1 < ordered.count,
               let right = ordered[(anchorIndex + 1)...].first(where: {
                   Self.isUsableAnchor($0, experimentalSystemItemHiding: experimentalSystemItemHiding)
               })
            {
                chain.append(.leftOfItem(right))
            }
        }

        return chain
    }

    private static func isUsableAnchor(
        _ item: MenuBarItem,
        experimentalSystemItemHiding: Bool
    ) -> Bool {
        !item.isSystemClone &&
            item.bounds.width > 0 &&
            item.isPhysicallyOrderable(experimentalSystemItemHiding: experimentalSystemItemHiding)
    }

    private func move(
        item: MenuBarItem,
        to destination: MenuBarItemManager.MoveDestination,
        sourceContainer: LayoutBarContainer? = nil,
        sectionOrderToCommit: [MenuBarItem]? = nil,
        anchorFallbacks: [MenuBarItemManager.MoveDestination] = []
    ) {
        guard let appState = container.appState else {
            return
        }
        isStabilizing = true
        Task { [self, appState] in
            await MainActor.run { self.setDimmed(true) }
            // Increased delay to allow macOS to settle after operations like Reset Layout.
            // Prevents transient errors when dragging items immediately after reset.
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                await MainActor.run {
                    self.isStabilizing = false
                    self.setDimmed(false)
                    self.finishDrag(sourceContainer: sourceContainer)
                }
                return
            }

            let watchdogTask = Task { [weak self, weak appState] in
                guard let self else { return }
                try? await Task.sleep(for: self.layoutWatchdogDuration() + .seconds(1))
                guard !Task.isCancelled else { return }
                await self.resetStabilizingStateIfNeeded()
                guard let appState else { return }
                await appState.itemManager.cacheItemsRegardless(skipRecentMoveCheck: true)
                await appState.imageCache.prewarmConcealedImages(
                    sections: MenuBarSection.Name.allCases,
                    onlyMissingImages: true
                )
                await appState.imageCache.recaptureNow(sections: MenuBarSection.Name.allCases)
            }
            var committed = false
            do {
                let recoveringStrandedVisibleControl = MenuBarItemGeometry.isStrandedVisibleControl(
                    item, screens: BarAxis.liveDisplayBounds()
                )
                let attemptMove = { () async throws -> Bool in
                    // A divider-anchored destination is a deliberate section transition;
                    // without the opt-in, move() refuses control item targets on macOS 27.
                    // A layout-pane drop is the user's direct action: it must preempt
                    // an in-flight background reconcile on the serial gate.
                    try await appState.itemManager.move(
                        item: item,
                        to: destination,
                        options: ItemMoveOptions(skipInputPause: true, allowSectionBoundaryTarget: destination.targetItem.isControlItem, allowParkedOffMenuBarSource: recoveringStrandedVisibleControl, anchorFallbacks: anchorFallbacks, isUserInitiated: true)
                    )
                }

                // The first attempt can fail while the bar is still settling after
                // a reset or a fresh reveal, by throwing or by answering false;
                // retry once either way, with refreshed bounds.
                var didMove = false
                var lastError: Error?
                for attempt in 1 ... 2 {
                    do {
                        didMove = try await attemptMove()
                        lastError = nil
                        if didMove {
                            break
                        }
                    } catch {
                        lastError = error
                    }
                    if attempt < 2 {
                        do {
                            try await Task.sleep(for: .milliseconds(150))
                        } catch {
                            break
                        }
                        await appState.itemManager.cacheItemsRegardless(skipRecentMoveCheck: true)
                    }
                }
                if let lastError {
                    throw lastError
                }
                // false means unfulfilled, not success. Never turn it into
                // a saved full-section request that moves other items instead.
                guard didMove else { throw MenuBarItemManager.EventError.cannotComplete }
                if let sectionOrderToCommit {
                    guard let liveItems = await MenuBarItem.getFreshMenuBarItemsForMove(priorityPIDs: Set([
                        item.ownerPID, item.sourcePID,
                        destination.targetItem.ownerPID, destination.targetItem.sourcePID,
                    ].compactMap(\.self))) else {
                        throw MenuBarItemManager.EventError.cannotComplete
                    }
                    try Task.checkCancellation()
                    guard let completedOrder = OrderRecording.sectionOrderAfterCompletedMove(
                        of: item,
                        proposedOrder: sectionOrderToCommit,
                        liveItems: liveItems
                    ) else { throw MenuBarItemManager.EventError.cannotComplete }
                    appState.menuBarManager.sectionController.setSectionOrder(
                        from: completedOrder,
                        for: container.section
                    )
                }
                committed = true
                appState.imageCache.performCacheCleanup()
                await appState.imageCache.recaptureNow(sections: [container.section])
            } catch {
                Self.diagLog.error("Error moving menu bar item: \(error)")
                if !Task.isCancelled {
                    appState.layoutFeedback.post(LayoutBarFeedbackCenter.itemCannotMove(itemName: item.displayName, section: container.section))
                }
            }
            watchdogTask.cancel()
            await MainActor.run {
                self.isStabilizing = false
                self.setDimmed(false)
            }
            if let appState = container.appState {
                await appState.itemManager.cacheItemsRegardless(skipRecentMoveCheck: true)
            }
            await MainActor.run {
                if committed, let appState = self.container.appState,
                   self.container.arrangedViews.contains(where: \.isNewItemsBadge)
                {
                    appState.itemManager.updateNewItemsPlacement(
                        section: self.container.section,
                        arrangedViews: self.container.arrangedViews
                    )
                }
                // Re-enable view updates on both the destination (frozen by
                // draggingEntered) and the source (frozen by willBeginAt on
                // the dragging session). Without resetting the source, its
                // arrangedViews would stay frozen at the mid-drag snapshot
                // until the next drag originated from that container.
                self.finishDrag(sourceContainer: sourceContainer)
            }
        }
    }

    @MainActor
    private func resetStabilizingStateIfNeeded() async {
        if isStabilizing {
            isStabilizing = false
            setDimmed(false)
            container.acceptsViewUpdates = true
        }
    }

    private func setDimmed(_ visible: Bool) {
        container.alphaValue = visible ? 0.6 : 1.0
    }

    /// Whether items in the section currently have live AX elements to reorder.
    private func sectionIsPhysicallyLive(
        _ section: MenuBarSection.Name,
        controller: (any MenuBarSectionControlling)?
    ) -> Bool {
        switch section {
        case .visible:
            return true
        case .hidden:
            guard container.appState?.navigationState.isThawBarPresented != true,
                  let revealed = controller?.revealedSection else {
                return false
            }
            return revealed == .hidden || revealed == .alwaysHidden
        case .alwaysHidden:
            return container.appState?.navigationState.isThawBarPresented != true &&
                controller?.revealedSection == .alwaysHidden
        }
    }

    /// Builds the ordered item list from the layout bar's current visual
    /// arrangement. The visible Thaw control (Thaw.ControlItem.Visible) is
    /// included so a layout-bar drag can commit the icon's new slot; hidden
    /// section dividers stay structural and are omitted.
    /// A collapsed group is one arranged view standing in for several items, so
    /// it must be expanded back into its members here. Matching only .item
    /// would drop every member of a collapsed group out of the persisted section
    /// order, the items would silently vanish from the saved layout while still
    /// being in the menu bar.
    static func layoutItemsForPersistence(from arrangedViews: [LayoutBarArrangedView]) -> [MenuBarItem] {
        persistableItems(from: arrangedViews.map(\.kind))
    }

    /// The pure kind-list form, so the expansion rule can be tested without a
    /// view tree, LayoutBarArrangedView.kind is get-only and the concrete
    /// views need an AppState.
    static func persistableItems(from kinds: [LayoutBarArrangedView.Kind]) -> [MenuBarItem] {
        kinds.flatMap { kind -> [MenuBarItem] in
            switch kind {
            case let .item(item):
                if item.isControlItem {
                    return item.tag.matchesVisibleControlItem ? [item] : []
                }
                return [item]
            case let .collapsedGroup(members):
                return members.filter { !$0.isControlItem }
            case .opaqueSlot, .newItemsBadge:
                return []
            }
        }
    }

    private func orderedLayoutItems() -> [MenuBarItem] {
        Self.layoutItemsForPersistence(from: arrangedViews)
    }

    /// The members of the dragged item's group in its source section, or nil
    /// when the item belongs to no group.
    ///
    /// The whole group travels together on a cross-section drop, honoring "one
    /// section per group", even if its members are not currently adjacent in
    /// the source section. Resolution goes through the shared resolver, so a
    /// user-authored group spanning several bundles moves as one unit exactly
    /// like an automatic same-bundle cluster does.
    private func crossSectionGroupMembers(
        for item: MenuBarItem,
        sourceSection: MenuBarSection.Name,
        controller: (any MenuBarSectionControlling)?
    ) -> [MenuBarItem]? {
        guard let appState = container.appState else {
            return nil
        }
        let managed = appState.itemManager.managedItems(for: sourceSection)
        // Display order, not recorded order: the indices below are read back
        // against the rows the user is dragging, so a group has to be resolved
        // over the same sequence the layout editor is showing.
        let sourceItems = controller?.displayOrdered(managed, in: sourceSection) ?? managed
        guard let group = appState.itemGroupManager.resolvedGroup(containing: item, in: sourceItems),
              group.count >= 2
        else {
            return nil
        }
        return group.memberIndices.compactMap { sourceItems.indices.contains($0) ? sourceItems[$0] : nil }
    }

    // MARK: Group handle drops

    /// Commits a whole-group drag started from a cluster's drag handle.
    ///
    /// Within the same section it reorders the group as one contiguous block
    /// (via persisted order + reconciliation, the same path a single reorder
    /// uses). Across sections it relocates every member, honoring "one section
    /// per group". Either way the group stays intact, individual items never
    /// fall out of a handle drag.
    private func performGroupHandleDrop(_ handle: LayoutBarGroupHandleView, sender: NSDraggingInfo) -> Bool {
        if handle.sourceSection == container.section {
            let dropX = container.convert(sender.draggingLocation, from: nil).x
            // The reorder path restores view updates itself (immediately for a
            // concealed section, or after its async move task for a live one).
            return performGroupHandleReorder(handle, dropX: dropX)
        }
        defer { restoreAfterGroupDrop(handle) }
        guard groupDropOperation(for: handle, at: sender.draggingLocation) == .move else { return false }
        return performGroupHandleCrossSection(handle)
    }

    /// Re-enables view updates on both the drop and source containers after a
    /// synchronous (no async move) group drop.
    private func restoreAfterGroupDrop(_ handle: LayoutBarGroupHandleView) {
        container.acceptsViewUpdates = true
        handle.sourceContainer?.acceptsViewUpdates = true
    }

    /// Reorders a group as one contiguous block within its current section,
    /// gathering its members even if they start scattered.
    ///
    /// In a concealed section the items are snapshots, so persisting the new
    /// order is enough. In a physically-live section (Visible, or a revealed
    /// hidden section) persistence alone does not move anything, the block is
    /// realized with real AX moves, one member at a time, then the final order
    /// is committed.
    private func performGroupHandleReorder(_ handle: LayoutBarGroupHandleView, dropX: CGFloat) -> Bool {
        guard let appState = container.appState else {
            restoreAfterGroupDrop(handle)
            return false
        }
        let controller = appState.menuBarManager.sectionController
        let orderedItems = orderedLayoutItems()
        let identifiers = orderedItems.map(\.uniqueIdentifier)

        // Members in their current left-to-right order, the sequence the
        // gathered block must end in. Membership is by identifier, so a bundle
        // whose items are not adjacent still contributes every member.
        let memberIDSet = Set(handle.memberIdentifiers)
        let members = orderedItems.filter { memberIDSet.contains($0.uniqueIdentifier) }
        guard members.count == handle.memberIdentifiers.count, members.count >= 2 else {
            // Some members are no longer present in this section (e.g. one was
            // pulled into another section); nothing to move as one block here.
            restoreAfterGroupDrop(handle)
            return false
        }

        // Drop cursor position in the original array's index space.
        let destination = container.groupDropDestination(atX: dropX).itemIndex

        // Gather: remove every member, then insert the block so it begins at the
        // drop cursor. Members sitting before the cursor shift the insertion left.
        var reordered = orderedItems.filter { !memberIDSet.contains($0.uniqueIdentifier) }
        let membersBefore = orderedItems.prefix(min(destination, orderedItems.count))
            .filter { memberIDSet.contains($0.uniqueIdentifier) }
            .count
        // The clamp is not a rendering detail to absorb quietly: firing at all
        // means the drag state disagrees with the section it dropped into, and
        // that disagreement is the defect worth logging.
        let rawInsertionIndex = destination - membersBefore
        let insertionIndex = rawInsertionIndex.clamped(to: 0 ... reordered.count)
        if rawInsertionIndex != insertionIndex {
            Self.diagLog.warning(
                "Group drop insertion index \(rawInsertionIndex) outside this section's 0...\(reordered.count); clamped to \(insertionIndex)"
            )
        }
        reordered.insert(contentsOf: members, at: insertionIndex)

        // Dropped where the block already sits, nothing to do.
        guard reordered.map(\.uniqueIdentifier) != identifiers else {
            restoreAfterGroupDrop(handle)
            return true
        }

        if sectionIsPhysicallyLive(container.section, controller: controller) {
            let firstIndex = insertionIndex
            let afterBlockIndex = firstIndex + members.count
            moveGroupSequentially(
                members: members,
                rightAnchor: afterBlockIndex < reordered.count ? reordered[afterBlockIndex] : nil,
                leftAnchor: firstIndex > 0 ? reordered[firstIndex - 1] : nil,
                sectionOrderToCommit: reordered,
                sourceContainer: handle.sourceContainer
            )
            // The async task calls finishDrag, which restores view updates.
            return true
        }

        controller.setSectionOrder(from: reordered, for: container.section)
        appState.itemManager.scheduleSectionOrderApply(for: container.section)
        Task { await appState.itemManager.cacheItemsRegardless(skipRecentMoveCheck: true) }
        restoreAfterGroupDrop(handle)
        return true
    }

    /// Realizes a block move in a physically-live section with sequential AX
    /// moves.
    ///
    /// The members are anchored to a fixed external neighbor, the item that
    /// borders the block's destination and is not itself a group member, never
    /// to a just-moved member (whose cached AX element is momentarily stale, the
    /// cause of members landing apart). Inserting each member adjacent to that
    /// stable anchor in the right order keeps the block contiguous: against a
    /// right neighbor, members go in front-to-back, each to its left; against
    /// a left neighbor, back-to-front, each to its right.
    private func moveGroupSequentially(
        members: [MenuBarItem],
        rightAnchor: MenuBarItem?,
        leftAnchor: MenuBarItem?,
        sectionOrderToCommit: [MenuBarItem],
        sourceContainer: LayoutBarContainer?
    ) {
        guard let appState = container.appState, !members.isEmpty else {
            finishDrag(sourceContainer: sourceContainer)
            return
        }
        let section = container.section
        // Members in left-to-right order, the sequence the block must end in.
        let memberOrder = members.map(\.tag)

        // Insert every member against a stable external anchor (never a
        // just-moved member). Front-to-back to the anchor's left, or, when the
        // block goes to the very end, back-to-front to a left anchor's right.
        let anchorTag: MenuBarItemTag
        let orderedMemberTags: [MenuBarItemTag]
        let insertToLeftOfAnchor: Bool
        if let rightAnchor {
            anchorTag = rightAnchor.tag
            orderedMemberTags = memberOrder
            insertToLeftOfAnchor = true
        } else if let leftAnchor {
            anchorTag = leftAnchor.tag
            orderedMemberTags = memberOrder.reversed()
            insertToLeftOfAnchor = false
        } else {
            finishDrag(sourceContainer: sourceContainer)
            return
        }

        Task { @MainActor [weak self, weak appState] in
            guard let self, let appState else { return }
            guard !self.isStabilizing else {
                self.finishDrag(sourceContainer: sourceContainer)
                return
            }
            self.isStabilizing = true
            self.setDimmed(true)
            try? await Task.sleep(for: .milliseconds(150))

            let liveOrder: @MainActor () -> [MenuBarItem] = {
                appState.itemManager.managedItems(for: section)
            }
            @MainActor func liveItem(_ tag: MenuBarItemTag) -> MenuBarItem? {
                liveOrder().first { $0.tag == tag }
            }
            let block = GroupBlockPlacement(members: memberOrder, anchor: anchorTag, insertsLeftOfAnchor: insertToLeftOfAnchor)
            let isPlaced: @MainActor () -> Bool = {
                let live = liveOrder().map(\.tag)
                if let slot = block.slot(in: live), slot.raw != slot.clamped {
                    Self.diagLog.warning(
                        "Group block slot \(slot.raw) outside the live section's 0...\(max(live.count - memberOrder.count, 0)); clamped to \(slot.clamped)"
                    )
                }
                return block.isPlaced(in: live)
            }

            // Repeat the placement pass until the whole block is contiguous; a
            // single AX move can transiently fail or lag the cache, which would
            // otherwise leave one member stranded outside the group.
            var pass = 0
            var runAnotherPass = true
            while runAnotherPass, !isPlaced() {
                pass += 1
                var membersMoved = 0
                for tag in orderedMemberTags {
                    // Re-fetch both the member and the (stable) anchor so each
                    // move targets a current AX element.
                    guard let member = liveItem(tag), let anchor = liveItem(anchorTag) else {
                        continue
                    }
                    let destination: MenuBarItemManager.MoveDestination =
                        insertToLeftOfAnchor ? .leftOfItem(anchor) : .rightOfItem(anchor)
                    var moved = false
                    do {
                        // User-driven group reorder: preempt background reconcile.
                        moved = try await appState.itemManager.move(
                            item: member,
                            to: destination,
                            options: ItemMoveOptions(skipInputPause: true, isUserInitiated: true)
                        )
                    } catch {
                        Self.diagLog.error("Group reorder move failed for \(member.logString): \(error)")
                    }
                    // A member macOS left in place changed nothing worth reading again.
                    guard moved else { continue }
                    membersMoved += 1
                    await appState.itemManager.cacheItemsRegardless(skipRecentMoveCheck: true)
                    // Let the AX order settle before the next member reads it.
                    try? await Task.sleep(for: .milliseconds(80))
                }
                runAnotherPass = GroupBlockPlacement.shouldRunAnotherPass(after: pass, membersMoved: membersMoved)
            }
            if !isPlaced() {
                Self.diagLog.warning("Group reorder did not converge after \(pass) of \(GroupBlockPlacement.maxPasses) passes")
                // The persisted order below is still canonical; what failed is
                // the physical AX placement. Say so rather than leaving a
                // half-regrouped cluster with no explanation.
                let sourceItems = appState.itemManager.managedItems(for: section)
                appState.layoutFeedback.post(
                    LayoutBarFeedbackCenter.groupRegatherIncomplete(
                        groupName: groupDisplayName(for: members, in: sourceItems, appState: appState),
                        section: section
                    )
                )
            }

            appState.menuBarManager.sectionController.setSectionOrder(
                from: sectionOrderToCommit,
                for: section
            )
            if !isPlaced() {
                // An explicitly requested group order still needs convergence.
                appState.itemManager.scheduleSectionOrderApply(for: section)
            }
            await appState.itemManager.cacheItemsRegardless(skipRecentMoveCheck: true)
            self.isStabilizing = false
            self.setDimmed(false)
            self.finishDrag(sourceContainer: sourceContainer)
        }
    }

    /// Relocates every member of a group into the drop section.
    private func performGroupHandleCrossSection(_ handle: LayoutBarGroupHandleView) -> Bool {
        guard let appState = container.appState else {
            return false
        }
        let sourceItems = appState.itemManager.managedItems(for: handle.sourceSection)
        let members = handle.memberIdentifiers.compactMap { identifier in
            sourceItems.first { $0.uniqueIdentifier == identifier }
        }
        guard !members.isEmpty else {
            return false
        }

        let drop = LayoutDropCommit.Drop(
            items: members,
            source: handle.sourceSection,
            target: container.section,
            previousTargetOrder: [],
            targetOrder: []
        )
        Task { @MainActor in
            if await LayoutDropCommit.perform(drop, appState: appState) {
                noteDropIntoHiddenSection(from: handle.sourceSection)
            }
        }
        return true
    }

    /// A user-facing name for the group these members belong to, for use in
    /// refusal copy.
    private func groupDisplayName(
        for members: [MenuBarItem],
        in sourceItems: [MenuBarItem],
        appState: AppState
    ) -> String {
        guard let first = members.first,
              let group = appState.itemGroupManager.resolvedGroup(containing: first, in: sourceItems)
        else {
            return members.first?.displayName ?? ""
        }
        return appState.itemGroupManager.displayName(for: group, in: sourceItems)
    }

    private func orderedLayoutItemsForSectionOrder() -> [MenuBarItem] {
        let orderedItems = orderedLayoutItems()
        guard container.section != .visible,
              !Self.allowsAnchoredSystemItemReordering(appState: container.appState)
        else {
            return orderedItems
        }
        return Self.anchoredSystemItemsTrail(in: orderedItems)
    }

    /// Fallback move target for the visible Thaw control when the planner
    /// cannot derive a destination from persisted order alone.
    private func visibleThawControlNeighborDestination(
        for item: MenuBarItem,
        at index: Int,
        experimentalSystemItemHiding: Bool
    ) -> MenuBarItemManager.MoveDestination? {
        guard item.tag.matchesVisibleControlItem else { return nil }
        if let target = nearestItem(
            toRightOf: index,
            requiringMovable: true,
            experimentalSystemItemHiding: experimentalSystemItemHiding
        ) {
            return .leftOfItem(target)
        }
        if let target = nearestItem(
            toLeftOf: index,
            requiringMovable: true,
            experimentalSystemItemHiding: experimentalSystemItemHiding
        ) {
            return .rightOfItem(target)
        }
        return nil
    }

    private func nearestItem(
        toRightOf index: Int,
        requiringMovable: Bool = false,
        experimentalSystemItemHiding: Bool = false
    ) -> MenuBarItem? {
        guard arrangedViews.indices.contains(index + 1) else {
            return nil
        }
        for candidateIndex in (index + 1) ..< arrangedViews.count {
            if case let .item(item) = arrangedViews[candidateIndex].kind {
                if requiringMovable,
                   item.isControlItem ||
                   !item.isPhysicallyOrderable(experimentalSystemItemHiding: experimentalSystemItemHiding)
                {
                    continue
                }
                return item
            }
        }
        return nil
    }

    private func nearestItem(
        toLeftOf index: Int,
        requiringMovable: Bool = false,
        experimentalSystemItemHiding: Bool = false
    ) -> MenuBarItem? {
        guard arrangedViews.indices.contains(index - 1) else {
            return nil
        }
        for candidateIndex in stride(from: index - 1, through: 0, by: -1) {
            if case let .item(item) = arrangedViews[candidateIndex].kind {
                if requiringMovable,
                   item.isControlItem ||
                   !item.isPhysicallyOrderable(experimentalSystemItemHiding: experimentalSystemItemHiding)
                {
                    continue
                }
                return item
            }
        }
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            updateNotchPresentation()
        }
    }

    private func configureNotchObservers(appState: AppState) {
        guard container.section == .visible else {
            return
        }

        // The notch is read from the settled displays.
        appState.displayEnvironment.settlements
            .sink { [weak self] _ in
                self?.updateNotchPresentation()
            }
            .store(in: &notchObservers)

        NotificationCenter.default
            .publisher(for: NSWindow.didChangeScreenNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      let notifyingWindow = notification.object as? NSWindow,
                      notifyingWindow === self.window
                else { return }
                self.updateNotchPresentation()
            }
            .store(in: &notchObservers)

        // The tint is part of the background the indicator is read against,
        // as it is for the items beside it.
        let colorTask = Task { @MainActor [weak self, menuBarManager = appState.menuBarManager, appearanceManager = appState.appearanceManager] in
            let changes = Observations {
                MenuBarStyleTint.background(
                    menuBarManager.averageColorInfo,
                    tintedBy: appearanceManager.configuration.current
                )
            }.removeDuplicates()
            for await colorInfo in changes {
                guard let self else { return }
                notchView?.averageColorInfo = colorInfo
            }
        }
        AnyCancellable { colorTask.cancel() }
            .store(in: &notchObservers)
    }

    private func updateNotchPresentation() {
        guard
            container.section == .visible,
            let screen = NSScreen.screenWithActiveMenuBar ?? NSScreen.main,
            screen.hasNotch,
            let notch = screen.frameOfNotch
        else {
            tearDownNotchPresentation()
            return
        }

        let notchIndicatorWidth = notch.width + MenuBarSection.notchGap
        // Distance from the bar's trailing edge to the notch indicator's
        // trailing edge, equals the real-world items area (everything
        // right of notch.maxX + notchGap in the menu bar) plus the 7.5pt
        // cosmetic inset that sits between items and the rounded edge.
        let notchTrailingOffset = max(0, screen.frame.maxX - notch.maxX - MenuBarSection.notchGap) + 7.5
        // Bar must always be wide enough to represent the real-world span
        // from notch.minX to screen.maxX, with no inset on the left
        // (the notch itself sits flush) and 7.5pt cosmetic inset on the
        // right. When the Settings pane is wider, the bar grows past this
        // and the empty area is shown to the LEFT of the notch.
        let barMinWidth = max(0, screen.frame.maxX - notch.minX) + 7.5
        let colorInfo = container.appState.flatMap { MenuBarStyleTint.currentBackground(appState: $0) }

        if let notchView {
            notchView.isHidden = false
            notchView.averageColorInfo = colorInfo
            notchWidthConstraint?.constant = notchIndicatorWidth
            notchTrailingConstraint?.constant = -notchTrailingOffset
            minWidthConstraint?.constant = barMinWidth
            containerLeadingInsetConstraint?.constant = 0
            return
        }

        let view = NotchIndicatorView(averageColorInfo: colorInfo)
        addSubview(view, positioned: .below, relativeTo: container)
        self.notchView = view

        let widthConstraint = view.widthAnchor.constraint(equalToConstant: notchIndicatorWidth)
        let trailingConstraint = view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -notchTrailingOffset)
        // .defaultHigh, not .required: a required pin at notchView.trailing
        // fixes the container's width, so overflowing items are clipped and
        // no horizontal scroller appears. At .defaultHigh the notch stays the
        // preferred boundary but AutoLayout can break it, the documentView
        // grows past the visible area and the scroller shows. The container
        // is z-above notchView, so items over the notch indicator stay
        // draggable.
        let containerLeading = container.leadingAnchor.constraint(greaterThanOrEqualTo: view.trailingAnchor)
        containerLeading.priority = .defaultHigh
        let minWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: barMinWidth)

        NSLayoutConstraint.activate([
            trailingConstraint,
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,
            containerLeading,
            minWidth,
        ])

        notchWidthConstraint = widthConstraint
        notchTrailingConstraint = trailingConstraint
        containerLeadingAfterNotchConstraint = containerLeading
        minWidthConstraint = minWidth
        containerLeadingInsetConstraint?.constant = 0
    }

    private func tearDownNotchPresentation() {
        notchWidthConstraint?.isActive = false
        notchTrailingConstraint?.isActive = false
        containerLeadingAfterNotchConstraint?.isActive = false
        minWidthConstraint?.isActive = false
        notchWidthConstraint = nil
        notchTrailingConstraint = nil
        containerLeadingAfterNotchConstraint = nil
        minWidthConstraint = nil
        containerLeadingInsetConstraint?.constant = -7.5
        notchView?.removeFromSuperview()
        notchView = nil
    }
}
