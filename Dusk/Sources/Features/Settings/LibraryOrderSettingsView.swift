import SwiftUI

/// Reorders the connected server's libraries. The order is an account-level Plex
/// setting, so it also drives the sidebar in Plex Web and the other Plex apps.
///
/// This view owns the view model and its load/error states for both platforms;
/// the editors differ because the input models do. iOS/iPadOS use native list
/// editing (`EditButton` + `onMove`). tvOS uses per-row position menus — the same
/// pattern as Navigation Tabs. **Do not replace the tvOS menus with a
/// focus-driven pick-up**: the previous Home layout editor did that and it was
/// unusable on a real remote (directional commands only reach an `onMoveCommand`
/// handler when the focus engine has no candidate, and the tab bar sits above
/// this screen).
struct LibraryOrderSettingsView: View {
    @Environment(PlexService.self) private var plexService
    @State private var viewModel: LibraryOrderSettingsViewModel?
    @State private var directionalFocus: PlexLibrary.ID?
    @State private var presentedChoice: DuskChoiceConfiguration?

    var body: some View {
        content
            .background(Color.duskBackground.ignoresSafeArea())
            .duskNavigationTitle("Library Order")
            .sheet(item: $presentedChoice) { DuskChoiceSheet(configuration: $0) }
            .duskNavigationBarTitleDisplayModeInline()
            .task {
                let model = viewModel ?? LibraryOrderSettingsViewModel(plexService: plexService)
                viewModel = model
                await model.load()
            }
            .onDisappear {
                guard let viewModel else { return }
                // The debounce may still be counting down; leaving the screen
                // must not drop the edit.
                Task { await viewModel.flushPendingWrite() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let viewModel {
            if viewModel.isLoading, viewModel.libraries.isEmpty {
                FeatureLoadingView()
            } else if let error = viewModel.error, viewModel.libraries.isEmpty {
                FeatureErrorView(message: error) {
                    Task { await viewModel.load() }
                }
            } else {
                editor(viewModel)
            }
        } else {
            FeatureLoadingView()
        }
    }

    @ViewBuilder
    private func editor(_ viewModel: LibraryOrderSettingsViewModel) -> some View {
        #if os(tvOS)
        tvEditor(viewModel)
        #else
        if ProcessInfo.processInfo.isiOSAppOnMac { directionalEditor(viewModel) }
        else { iosEditor(viewModel) }
        #endif
    }

    // MARK: - iOS

    #if !os(tvOS)
    private func directionalEditor(_ viewModel: LibraryOrderSettingsViewModel) -> some View {
        DuskDirectionalFocusScope(
            focusedID: $directionalFocus,
            groups: [.grid(viewModel.libraries.map(\.id), columnCount: 1)],
            isEnabled: presentedChoice == nil,
            onActivate: { id in
                guard let library = viewModel.libraries.first(where: { $0.id == id }) else { return false }
                choosePosition(viewModel, for: library)
                return true
            }
        ) {
            ScrollViewReader { proxy in
                List {
                    Section {
                        ForEach(viewModel.libraries) { library in
                            Button { choosePosition(viewModel, for: library) } label: {
                                HStack {
                                    Label(library.title, systemImage: Self.iconName(for: library))
                                    Spacer()
                                    Text("Position \((viewModel.libraries.firstIndex(of: library) ?? 0) + 1)")
                                        .foregroundStyle(Color.duskTextSecondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .duskDirectionalFocusHighlight(directionalFocus == library.id, shape: RoundedRectangle(cornerRadius: 12))
                            .id(library.id)
                            .listRowBackground(Color.duskSurface)
                        }
                    } footer: {
                        Text("Choose a library's position. The order is saved to your Plex account.")
                    }
                    if let error = viewModel.saveError { Text(error).foregroundStyle(Color.duskTextSecondary) }
                }
                .duskScrollContentBackgroundHidden()
                .onChange(of: directionalFocus) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }

    private func choosePosition(_ viewModel: LibraryOrderSettingsViewModel, for library: PlexLibrary) {
        presentedChoice = DuskChoiceConfiguration(
            title: library.title,
            options: viewModel.libraries.indices.map { "Position \($0 + 1)" },
            selectedIndex: viewModel.libraries.firstIndex(of: library) ?? 0,
            onSelect: { viewModel.move(library, to: $0) }
        )
    }

    private func iosEditor(_ viewModel: LibraryOrderSettingsViewModel) -> some View {
        List {
            Section {
                ForEach(viewModel.libraries) { library in
                    Label(library.title, systemImage: Self.iconName(for: library))
                        .foregroundStyle(Color.duskTextPrimary)
                }
                .onMove { offsets, destination in
                    viewModel.move(fromOffsets: offsets, toOffset: destination)
                }
            } header: {
                HStack {
                    Text("Order")
                        .foregroundStyle(Color.duskTextSecondary)

                    Spacer()

                    if viewModel.isSaving {
                        ProgressView()
                            .tint(Color.duskAccent)
                    }
                }
            } footer: {
                Text("Drag to set the order of your libraries. The order is saved to your Plex account, so other Plex apps use it too.")
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            if let saveError = viewModel.saveError {
                Section {
                    Text(saveError)
                        .foregroundStyle(Color.duskTextSecondary)
                }
                .listRowBackground(Color.duskSurface)
            }
        }
        .contentMargins(.top, 12, for: .scrollContent)
        .duskScrollContentBackgroundHidden()
        .toolbar {
            EditButton()
        }
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private func tvEditor(_ viewModel: LibraryOrderSettingsViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                TVSettingsSection(
                    title: "Order",
                    footer: "Choose the position of each library. The order is saved to your Plex account, so other Plex apps use it too."
                ) {
                    ForEach(Array(viewModel.libraries.enumerated()), id: \.element) { index, library in
                        if index > 0 {
                            tvRowDivider
                        }

                        TVSettingsMenuRow(
                            title: library.title,
                            options: Array(viewModel.libraries.indices),
                            selection: positionBinding(viewModel, for: library),
                            selectedTitle: LibraryOrderPositionName.label(for: index)
                        ) {
                            LibraryOrderPositionName.label(for: $0)
                        }
                    }
                }

                if let saveError = viewModel.saveError {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundStyle(Color.duskTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, TVSettingsMetrics.contentInset)
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

    private func positionBinding(
        _ viewModel: LibraryOrderSettingsViewModel,
        for library: PlexLibrary
    ) -> Binding<Int> {
        Binding(
            get: { viewModel.position(of: library) },
            set: { viewModel.move(library, to: $0) }
        )
    }
    #endif

    // MARK: - Shared

    /// Music and photo sections are listed here even though Dusk cannot browse
    /// them, so they need icons `PlexLibraryType` does not model.
    private static func iconName(for library: PlexLibrary) -> String {
        if let systemImage = library.libraryType?.systemImage {
            return systemImage
        }

        switch library.type {
        case "artist":
            return "music.note"
        case "photo":
            return "photo"
        default:
            return "folder"
        }
    }
}

#if os(tvOS)
/// Position labels for the tvOS order menus. Formatted rather than hardcoded so
/// the list is not capped at a handful of names — a server can have any number of
/// sections. `NumberFormatter` is not `Sendable`, so the cached instance is
/// pinned to the main actor.
@MainActor
private enum LibraryOrderPositionName {
    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter
    }()

    static func label(for index: Int) -> String {
        formatter.string(from: NSNumber(value: index + 1)) ?? "\(index + 1)"
    }
}
#endif
