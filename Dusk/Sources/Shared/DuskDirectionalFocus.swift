import SwiftUI

/// A logical row or grid of controls inside one directional focus scope.
/// Screens describe their layout with groups; the scope owns keyboard/controller
/// movement, default focus, activation, and repairing focus after content changes.
struct DuskDirectionalFocusGroup<ID: Hashable>: Equatable {
    let targets: [ID]
    let columnCount: Int

    init(targets: [ID], columnCount: Int) {
        self.targets = targets
        self.columnCount = max(columnCount, 1)
    }

    static func single(_ target: ID) -> Self {
        Self(targets: [target], columnCount: 1)
    }

    static func row(_ targets: [ID]) -> Self {
        Self(targets: targets, columnCount: max(targets.count, 1))
    }

    static func grid(_ targets: [ID], columnCount: Int) -> Self {
        Self(targets: targets, columnCount: columnCount)
    }
}

struct DuskDirectionalFocusScope<ID: Hashable, Content: View>: View {
    @Binding private var focusedID: ID?
    @State private var hasUserMovedFocus = false

    private let groups: [DuskDirectionalFocusGroup<ID>]
    private let defaultFocus: ID?
    private let isEnabled: Bool
    private let onActivate: (ID) -> Bool
    private let onBack: (() -> Bool)?
    private let onDirectionalInputChanged: ((KeyEquivalent, Bool) -> Bool)?
    private let onDirectionalBoundary: (KeyEquivalent, ID) -> Bool
    private let content: Content

    init(
        focusedID: Binding<ID?>,
        groups: [DuskDirectionalFocusGroup<ID>],
        defaultFocus: ID? = nil,
        isEnabled: Bool,
        onActivate: @escaping (ID) -> Bool,
        onBack: (() -> Bool)? = nil,
        onDirectionalInputChanged: ((KeyEquivalent, Bool) -> Bool)? = nil,
        onDirectionalBoundary: @escaping (KeyEquivalent, ID) -> Bool = { _, _ in false },
        @ViewBuilder content: () -> Content
    ) {
        _focusedID = focusedID
        self.groups = groups
        self.defaultFocus = defaultFocus
        self.isEnabled = isEnabled
        self.onActivate = onActivate
        self.onBack = onBack
        self.onDirectionalInputChanged = onDirectionalInputChanged
        self.onDirectionalBoundary = onDirectionalBoundary
        self.content = content()
    }

    var body: some View {
        content
            .overlay(alignment: .topLeading) {
                #if os(iOS)
                if isEnabled,
                   onBack != nil || groups.contains(where: { !$0.targets.isEmpty }) {
                    DuskDirectionalInputBridge(
                        onDirectionalInput: moveFocus(for:),
                        onDirectionalInputChanged: onDirectionalInputChanged,
                        onActivate: activateFocus,
                        onBack: onBack
                    )
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                }
                #endif
            }
            .onAppear(perform: repairFocus)
            .onChange(of: groups) { _, _ in
                repairFocus()
            }
            .onChange(of: defaultFocus) { _, _ in
                repairFocus()
            }
            .onChange(of: isEnabled) { _, _ in
                repairFocus()
            }
    }

    private func repairFocus() {
        guard isEnabled else {
            hasUserMovedFocus = false
            focusedID = nil
            return
        }

        // Async screens may expose a fallback group before their preferred action
        // is available. Promote that preferred default once it appears, but never
        // override a target the user has deliberately moved to.
        if !hasUserMovedFocus, let defaultFocus, contains(defaultFocus) {
            focusedID = defaultFocus
            return
        }

        if let focusedID, contains(focusedID) {
            return
        }

        if let defaultFocus, contains(defaultFocus) {
            focusedID = defaultFocus
        } else {
            focusedID = groups.lazy.compactMap(\.targets.first).first
        }
    }

    private func moveFocus(for key: KeyEquivalent) -> Bool {
        guard isEnabled, isDirectionalKey(key) else { return false }

        guard let source = resolvedFocus,
              let location = location(of: source) else {
            repairFocus()
            return focusedID != nil
        }

        if let destination = destination(from: location, for: key) {
            hasUserMovedFocus = true
            focusedID = destination
        } else {
            _ = onDirectionalBoundary(key, source)
        }

        // Consume directional input at an edge so the enclosing ScrollView does
        // not move independently of the visible selection.
        return true
    }

    private func activateFocus() -> Bool {
        guard isEnabled, let target = resolvedFocus else { return false }
        if focusedID == nil {
            focusedID = target
        }
        return onActivate(target)
    }

    private var resolvedFocus: ID? {
        if let focusedID, contains(focusedID) {
            return focusedID
        }
        if let defaultFocus, contains(defaultFocus) {
            return defaultFocus
        }
        return groups.lazy.compactMap(\.targets.first).first
    }

    private func contains(_ target: ID) -> Bool {
        groups.contains { $0.targets.contains(target) }
    }

    private func location(of target: ID) -> (group: Int, item: Int)? {
        for (groupIndex, group) in groups.enumerated() {
            if let itemIndex = group.targets.firstIndex(of: target) {
                return (groupIndex, itemIndex)
            }
        }
        return nil
    }

    private func destination(
        from location: (group: Int, item: Int),
        for key: KeyEquivalent
    ) -> ID? {
        let group = groups[location.group]
        let columns = group.columnCount
        let column = location.item % columns

        switch key {
        case .leftArrow:
            guard column > 0 else { return nil }
            return group.targets[location.item - 1]
        case .rightArrow:
            let next = location.item + 1
            guard column + 1 < columns, group.targets.indices.contains(next) else { return nil }
            return group.targets[next]
        case .upArrow:
            let previousRow = location.item - columns
            if group.targets.indices.contains(previousRow) {
                return group.targets[previousRow]
            }
            return adjacentTarget(
                startingAt: location.group - 1,
                step: -1,
                preferredColumn: column,
                entersAtBottom: true
            )
        case .downArrow:
            let nextRow = location.item + columns
            if group.targets.indices.contains(nextRow) {
                return group.targets[nextRow]
            }
            return adjacentTarget(
                startingAt: location.group + 1,
                step: 1,
                preferredColumn: column,
                entersAtBottom: false
            )
        default:
            return nil
        }
    }

    private func adjacentTarget(
        startingAt start: Int,
        step: Int,
        preferredColumn: Int,
        entersAtBottom: Bool
    ) -> ID? {
        var groupIndex = start
        while groups.indices.contains(groupIndex) {
            let group = groups[groupIndex]
            if !group.targets.isEmpty {
                if entersAtBottom {
                    let lastRowStart = ((group.targets.count - 1) / group.columnCount) * group.columnCount
                    let lastRowCount = group.targets.count - lastRowStart
                    return group.targets[lastRowStart + min(preferredColumn, lastRowCount - 1)]
                }
                return group.targets[min(preferredColumn, group.targets.count - 1)]
            }
            groupIndex += step
        }
        return nil
    }

    private func isDirectionalKey(_ key: KeyEquivalent) -> Bool {
        key == .leftArrow || key == .rightArrow || key == .upArrow || key == .downArrow
    }
}

private struct DuskDirectionalFocusHighlightModifier<FocusShape: Shape>: ViewModifier {
    let isFocused: Bool
    let shape: FocusShape

    func body(content: Content) -> some View {
        content
            .overlay {
                if isFocused {
                    shape
                        .stroke(Color.duskAccent, lineWidth: 3)
                        .padding(-5)
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(isFocused ? 1.025 : 1)
            .shadow(color: isFocused ? Color.duskAccent.opacity(0.32) : .clear, radius: 12)
            .animation(.easeOut(duration: 0.12), value: isFocused)
            .zIndex(isFocused ? 1 : 0)
            .accessibilityAddTraits(isFocused ? [.isSelected] : [])
    }
}

extension View {
    func duskDirectionalFocusHighlight<FocusShape: Shape>(
        _ isFocused: Bool,
        shape: FocusShape
    ) -> some View {
        modifier(DuskDirectionalFocusHighlightModifier(isFocused: isFocused, shape: shape))
    }
}
