import SwiftUI

struct DuskChoiceConfiguration: Identifiable {
    var id: String { title }
    let title: String
    let options: [String]
    let selectedIndex: Int
    let onSelect: (Int) -> Void
}

/// Touch and controller users see the same explicit list of choices.
struct DuskChoiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var focusedIndex: Int?
    let configuration: DuskChoiceConfiguration

    private var usesDirectionalSelection: Bool {
        #if os(iOS)
        ProcessInfo.processInfo.isiOSAppOnMac
        #else
        false
        #endif
    }

    var body: some View {
        DuskDirectionalFocusScope(
            focusedID: $focusedIndex,
            groups: [.grid(Array(configuration.options.indices), columnCount: 1)],
            defaultFocus: configuration.selectedIndex,
            isEnabled: usesDirectionalSelection,
            onActivate: select,
            onBack: { dismiss(); return true }
        ) {
            NavigationStack {
                ScrollViewReader { proxy in
                    List {
                        ForEach(configuration.options.indices, id: \.self) { index in
                            Button { _ = select(index) } label: {
                                HStack {
                                    Text(configuration.options[index])
                                        .foregroundStyle(Color.duskTextPrimary)
                                    Spacer()
                                    if index == configuration.selectedIndex {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.duskAccent)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focusable(!usesDirectionalSelection)
                            .duskDirectionalFocusHighlight(focusedIndex == index, shape: RoundedRectangle(cornerRadius: 12))
                            .id(index)
                            .listRowBackground(Color.duskSurface)
                        }
                    }
                    .duskScrollContentBackgroundHidden()
                    .background(Color.duskBackground)
                    .onChange(of: focusedIndex) { _, index in
                        if let index {
                            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(index, anchor: .center) }
                        }
                    }
                }
                .duskNavigationTitle(configuration.title)
                .duskNavigationBarTitleDisplayModeInline()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.duskBackground)
    }

    private func select(_ index: Int) -> Bool {
        guard configuration.options.indices.contains(index) else { return false }
        configuration.onSelect(index)
        dismiss()
        return true
    }
}
