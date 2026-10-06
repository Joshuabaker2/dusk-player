import SwiftUI

struct LibraryTabSettingsView: View {
    @Environment(UserPreferences.self) private var preferences
    @State private var directionalFocus: Target?
    @State private var presentedChoice: DuskChoiceConfiguration?

    private enum Target: Hashable {
        case visibility(PlexLibraryType)
        case position(PlexLibraryType)
    }

    var body: some View {
        Group {
            #if os(tvOS)
            tvContent
            #else
            if ProcessInfo.processInfo.isiOSAppOnMac { directionalContent }
            else { iosContent }
            #endif
        }
        .background(Color.duskBackground.ignoresSafeArea())
        .duskNavigationTitle("Navigation Tabs")
        .sheet(item: $presentedChoice) { DuskChoiceSheet(configuration: $0) }
    }

    #if !os(tvOS)
    private var directionalContent: some View {
        DuskDirectionalFocusScope(
            focusedID: $directionalFocus,
            groups: [
                .grid(preferences.libraryTabOrder.map { .visibility($0) }, columnCount: 1),
                .grid(preferences.libraryTabOrder.map { .position($0) }, columnCount: 1)
            ],
            isEnabled: presentedChoice == nil,
            onActivate: { target in
                switch target {
                case .visibility(let type):
                    preferences.setLibraryTabVisible(!preferences.isLibraryTabVisible(type), for: type)
                case .position(let type):
                    presentedChoice = DuskChoiceConfiguration(
                        title: type.tabTitle,
                        options: preferences.libraryTabOrder.indices.map { "Position \($0 + 1)" },
                        selectedIndex: preferences.libraryTabOrder.firstIndex(of: type) ?? 0,
                        onSelect: { preferences.moveLibraryTab(type, to: $0) }
                    )
                }
                return true
            }
        ) {
            ScrollViewReader { proxy in
                List {
                    Section("Visibility") {
                        ForEach(preferences.libraryTabOrder, id: \.self) { type in
                            Toggle(type.tabTitle, isOn: visibilityBinding(for: type))
                                .focusable(false)
                                .duskDirectionalFocusHighlight(directionalFocus == .visibility(type), shape: RoundedRectangle(cornerRadius: 12))
                                .id(Target.visibility(type))
                                .listRowBackground(Color.duskSurface)
                        }
                    }
                    Section("Order") {
                        ForEach(preferences.libraryTabOrder, id: \.self) { type in
                            Button {
                                presentedChoice = DuskChoiceConfiguration(
                                    title: type.tabTitle,
                                    options: preferences.libraryTabOrder.indices.map { "Position \($0 + 1)" },
                                    selectedIndex: preferences.libraryTabOrder.firstIndex(of: type) ?? 0,
                                    onSelect: { preferences.moveLibraryTab(type, to: $0) }
                                )
                            } label: {
                                HStack {
                                    Text(type.tabTitle)
                                    Spacer()
                                    Text("Position \((preferences.libraryTabOrder.firstIndex(of: type) ?? 0) + 1)")
                                        .foregroundStyle(Color.duskTextSecondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .duskDirectionalFocusHighlight(directionalFocus == .position(type), shape: RoundedRectangle(cornerRadius: 12))
                            .id(Target.position(type))
                            .listRowBackground(Color.duskSurface)
                        }
                    }
                }
                .duskScrollContentBackgroundHidden()
                .onChange(of: directionalFocus) { _, target in
                    if let target { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(target, anchor: .center) } }
                }
            }
        }
    }

    private var iosContent: some View {
        List {
            Section {
                ForEach(preferences.libraryTabOrder, id: \.self) { libraryType in
                    Toggle(
                        isOn: visibilityBinding(for: libraryType)
                    ) {
                        Label(libraryType.tabTitle, systemImage: libraryType.systemImage)
                            .foregroundStyle(Color.duskTextPrimary)
                    }
                    .tint(Color.duskAccent)
                }
                .onMove(perform: preferences.moveLibraryTabs)
            } header: {
                Text("Navigation Tabs")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text("Turn off a destination to remove it from the navigation bar. Tap Edit, then drag to change the order.")
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)
        }
        .contentMargins(.top, 12, for: .scrollContent)
        .duskScrollContentBackgroundHidden()
        .toolbar {
            EditButton()
        }
    }
    #endif

    #if os(tvOS)
    private var tvContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                TVSettingsSection(
                    title: "Visibility",
                    footer: "Turn off a destination to remove it from the navigation bar."
                ) {
                    ForEach(Array(preferences.libraryTabOrder.enumerated()), id: \.element) { index, libraryType in
                        if index > 0 {
                            tvRowDivider
                        }

                        TVSettingsToggleRow(
                            title: libraryType.tabTitle,
                            isOn: visibilityBinding(for: libraryType)
                        )
                    }
                }

                TVSettingsSection(
                    title: "Order",
                    footer: "Choose the position of each destination in the navigation bar."
                ) {
                    ForEach(Array(preferences.libraryTabOrder.enumerated()), id: \.element) { index, libraryType in
                        if index > 0 {
                            tvRowDivider
                        }

                        TVSettingsMenuRow(
                            title: libraryType.tabTitle,
                            options: Array(preferences.libraryTabOrder.indices),
                            selection: positionBinding(for: libraryType),
                            selectedTitle: positionName(for: index)
                        ) {
                            positionName(for: $0)
                        }
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.top, 48)
            .padding(.bottom, 88)
        }
    }

    private var tvRowDivider: some View {
        Rectangle()
            .fill(Color.duskTextSecondary.opacity(0.16))
            .frame(height: 1)
    }

    private func positionBinding(for libraryType: PlexLibraryType) -> Binding<Int> {
        Binding(
            get: { preferences.libraryTabOrder.firstIndex(of: libraryType) ?? 0 },
            set: { preferences.moveLibraryTab(libraryType, to: $0) }
        )
    }

    private func positionName(for index: Int) -> String {
        switch index {
        case 0:
            "First"
        case 1:
            "Second"
        default:
            index == 2 ? "Third" : "Fourth"
        }
    }
    #endif

    private func visibilityBinding(for libraryType: PlexLibraryType) -> Binding<Bool> {
        Binding(
            get: { preferences.isLibraryTabVisible(libraryType) },
            set: { preferences.setLibraryTabVisible($0, for: libraryType) }
        )
    }
}
