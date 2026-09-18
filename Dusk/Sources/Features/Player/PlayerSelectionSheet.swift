import SwiftUI

private enum PlayerSelectionTarget<ID: Hashable>: Hashable {
    case deselection
    case item(ID)
    case extra(String)
}

/// A non-selectable row appended below a selection list — the subtitle delay
/// adjuster and "Find More…". These participate in the list's directional focus
/// scope, so keyboard and controller users can reach them like any track row.
struct PlayerSelectionExtraRow: Identifiable {
    /// Inline -/+ control. Left/Right adjust it while the row has directional
    /// focus; the buttons stay for touch and pointer input.
    struct Adjuster {
        let onDecrease: () -> Void
        let onIncrease: () -> Void
        let onReset: () -> Void
        let canReset: Bool
    }

    let id: String
    let title: String
    var subtitle: String?
    var systemImage: String?
    var adjuster: Adjuster?
    /// Run on tap and on Return/controller A. Rows that only carry an adjuster
    /// use it to reset.
    var action: () -> Void
}

struct PlayerSelectionSheet<Item: Identifiable>: View {
    let title: String
    var allowsDeselection = false
    var deselectionTitle = "Off"
    let items: [Item]
    let selectedID: Item.ID?
    let itemTitle: KeyPath<Item, String>
    let itemSubtitle: KeyPath<Item, String?>
    let onSelect: (Item?) -> Void
    let onDismiss: () -> Void
    /// Rows appended below the selectable items (subtitle delay, "Find More…"),
    /// included in the directional focus scope.
    var extraRows: [PlayerSelectionExtraRow] = []
    @State private var directionalFocus: PlayerSelectionTarget<Item.ID>?

    var body: some View {
        DuskDirectionalFocusScope(
            focusedID: $directionalFocus,
            groups: [.grid(selectionTargets, columnCount: 1)],
            defaultFocus: defaultDirectionalFocus,
            isEnabled: supportsDirectionalSelection,
            onActivate: activateDirectionalFocus,
            onBack: {
                onDismiss()
                return true
            },
            onDirectionalBoundary: adjustDirectionalFocus
        ) {
            NavigationStack {
                ScrollViewReader { proxy in
                    List {
                        if allowsDeselection {
                            selectionButton(
                                target: .deselection,
                                title: deselectionTitle,
                                subtitle: nil,
                                isSelected: selectedID == nil,
                                action: { onSelect(nil) }
                            )
                        }

                        ForEach(items) { item in
                            selectionButton(
                                target: .item(item.id),
                                title: item[keyPath: itemTitle],
                                subtitle: item[keyPath: itemSubtitle],
                                isSelected: selectedID == item.id,
                                action: { onSelect(item) }
                            )
                        }

                        ForEach(extraRows) { row in
                            extraRowView(row)
                        }
                    }
                    .duskScrollContentBackgroundHidden()
                    .background(Color.duskBackground)
                    .onChange(of: directionalFocus) { _, target in
                        guard let target else { return }
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
                .duskNavigationTitle(title)
                .duskNavigationBarTitleDisplayModeInline()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: onDismiss)
                            .duskSuppressTVOSButtonChrome()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(Color.duskBackground)
    }

    private var selectionTargets: [PlayerSelectionTarget<Item.ID>] {
        (allowsDeselection ? [.deselection] : [])
            + items.map { .item($0.id) }
            + extraRows.map { .extra($0.id) }
    }

    private var defaultDirectionalFocus: PlayerSelectionTarget<Item.ID>? {
        if let selectedID, items.contains(where: { $0.id == selectedID }) {
            return .item(selectedID)
        }
        if allowsDeselection {
            return .deselection
        }
        return items.first.map { .item($0.id) }
    }

    private var supportsDirectionalSelection: Bool {
        #if os(iOS)
        ProcessInfo.processInfo.isiOSAppOnMac
        #else
        false
        #endif
    }

    private func activateDirectionalFocus(_ target: PlayerSelectionTarget<Item.ID>) -> Bool {
        switch target {
        case .deselection:
            guard allowsDeselection else { return false }
            onSelect(nil)
        case let .item(itemID):
            guard let item = items.first(where: { $0.id == itemID }) else { return false }
            onSelect(item)
        case let .extra(rowID):
            guard let row = extraRows.first(where: { $0.id == rowID }) else { return false }
            row.action()
        }
        return true
    }

    private func adjustDirectionalFocus(
        _ key: KeyEquivalent,
        target: PlayerSelectionTarget<Item.ID>
    ) -> Bool {
        guard case let .extra(rowID) = target,
              let adjuster = extraRows.first(where: { $0.id == rowID })?.adjuster else {
            return false
        }

        switch key {
        case .leftArrow:
            adjuster.onDecrease()
        case .rightArrow:
            adjuster.onIncrease()
        default:
            return false
        }
        return true
    }


    @ViewBuilder
    private func extraRowView(_ row: PlayerSelectionExtraRow) -> some View {
        PlayerSelectionExtraRowView(
            row: row,
            isDirectionallyFocused: supportsDirectionalSelection && directionalFocus == .extra(row.id),
            isFocusable: !supportsDirectionalSelection
        )
        .id(PlayerSelectionTarget<Item.ID>.extra(row.id))
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowBackground(Color.duskSurface)
        .duskSuppressTVOSButtonChrome()
    }

    private func selectionButton(
        target: PlayerSelectionTarget<Item.ID>,
        title: String,
        subtitle: String?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            pickerRow(title: title, subtitle: subtitle, isSelected: isSelected)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(!supportsDirectionalSelection)
        .duskDirectionalFocusHighlight(
            supportsDirectionalSelection && directionalFocus == target,
            shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .id(target)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowBackground(Color.duskSurface)
        .duskSuppressTVOSButtonChrome()
    }

    private func pickerRow(title: String, subtitle: String?, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(Color.duskTextPrimary)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.duskTextSecondary)
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.duskAccent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if !os(tvOS)
/// A single focus-friendly playback settings surface for iPhone, iPad, and
/// the iPad app running on Apple silicon Mac.
/// Keeping each destination inside one NavigationStack avoids nested `Menu`
/// popovers, which are awkward to traverse with a game controller.
struct PlayerPlaybackSettingsSheet: View {
    let playback: PlaybackCoordinator
    let viewModel: PlayerViewModel
    let context: PlayerControlsContext
    let onShowPlaybackInfo: () -> Void
    let onDismiss: () -> Void
    /// Non-nil when subtitle search is available for this session (absent for
    /// Live TV, which has no library item to search against).
    var subtitleSearch: PlayerSubtitleSearchConfiguration?
    @State private var navigationPath: [Destination] = []
    @State private var directionalFocus: Destination?

    private enum Destination: Hashable {
        case channels
        case quality
        case audio
        case subtitles
        case findSubtitles
        case playbackInfo
    }

    var body: some View {
        settingsNavigation
            .presentationDetents([.medium, .large])
            .presentationBackground(Color.duskBackground)
    }

    private var settingsNavigation: some View {
        DuskDirectionalFocusScope(
            focusedID: $directionalFocus,
            groups: [.grid(directionalDestinations, columnCount: 1)],
            defaultFocus: directionalDestinations.first,
            isEnabled: supportsDirectionalSelection && navigationPath.isEmpty,
            onActivate: activateDestination,
            onBack: {
                onDismiss()
                return true
            }
        ) {
            NavigationStack(path: $navigationPath) {
                List {
                    if context.liveTVContext != nil {
                        settingsLink(
                            destination: .channels,
                            title: "Channel",
                            subtitle: currentChannelTitle,
                            icon: "list.number",
                            isEnabled: true
                        )
                    }

                    if context.hasQualityControl {
                        settingsLink(
                            destination: .quality,
                            title: "Quality",
                            subtitle: context.qualityControlTitle,
                            icon: "rectangle.compress.vertical",
                            isEnabled: context.canSelectQuality && !context.isChangingQuality
                        )
                    }

                    settingsLink(
                        destination: .audio,
                        title: "Audio",
                        subtitle: context.audioControlTitle,
                        icon: "speaker.wave.2",
                        isEnabled: !viewModel.audioTracks.isEmpty
                    )

                    settingsLink(
                        destination: .subtitles,
                        title: "Subtitles",
                        subtitle: context.subtitleControlTitle,
                        icon: viewModel.selectedSubtitleTrack == nil
                            ? "captions.bubble"
                            : "captions.bubble.fill",
                        // Stays enabled with no tracks: subtitle search lives
                        // inside this destination.
                        isEnabled: true
                    )

                    if context.hasPlaybackInfo {
                        Button(action: onShowPlaybackInfo) {
                            settingsRow(
                                title: "Get Info",
                                subtitle: nil,
                                icon: "info.circle"
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.duskSurface)
                        .focusable(!supportsDirectionalSelection)
                        .duskDirectionalFocusHighlight(
                            directionalFocus == .playbackInfo,
                            shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                    }
                }
                .duskScrollContentBackgroundHidden()
                .background(Color.duskBackground)
                .duskNavigationTitle("Playback Settings")
                .duskNavigationBarTitleDisplayModeInline()
                .navigationDestination(for: Destination.self) { destination in
                    destinationView(destination)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: onDismiss)
                            .duskSuppressTVOSButtonChrome()
                    }
                }
            }
        }
    }

    private var supportsDirectionalSelection: Bool {
        #if os(iOS)
        ProcessInfo.processInfo.isiOSAppOnMac
        #else
        false
        #endif
    }

    private var directionalDestinations: [Destination] {
        var destinations: [Destination] = []
        if context.liveTVContext != nil {
            destinations.append(.channels)
        }
        if context.hasQualityControl && context.canSelectQuality && !context.isChangingQuality {
            destinations.append(.quality)
        }
        if !viewModel.audioTracks.isEmpty {
            destinations.append(.audio)
        }
        destinations.append(.subtitles)
        if context.hasPlaybackInfo {
            destinations.append(.playbackInfo)
        }
        return destinations
    }

    private func activateDestination(_ destination: Destination) -> Bool {
        guard directionalDestinations.contains(destination) else { return false }
        if destination == .playbackInfo {
            onShowPlaybackInfo()
        } else {
            navigationPath.append(destination)
        }
        return true
    }

    private var currentChannelTitle: String {
        guard let live = context.liveTVContext else { return "Unavailable" }
        return [live.channel.displayNumber, live.channel.displayTitle]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func settingsLink(
        destination: Destination,
        title: String,
        subtitle: String,
        icon: String,
        isEnabled: Bool
    ) -> some View {
        NavigationLink(value: destination) {
            settingsRow(title: title, subtitle: subtitle, icon: icon)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.duskSurface)
        .disabled(!isEnabled)
        .focusable(!supportsDirectionalSelection)
        .duskDirectionalFocusHighlight(
            directionalFocus == destination,
            shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func settingsRow(
        title: String,
        subtitle: String?,
        icon: String
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(Color.duskTextPrimary)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.duskTextSecondary)
                }
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(Color.duskTextPrimary)
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: Destination) -> some View {
        switch destination {
        case .channels:
            channelSelection
        case .quality:
            PlayerSettingsSelectionList(
                title: "Quality",
                items: context.availableQualityPresets,
                isSelected: { context.selectedQualityPreset == $0 },
                itemTitle: { $0.displayName },
                itemSubtitle: { $0.detailTitle },
                onSelect: { preset in
                    guard preset != context.selectedQualityPreset else { return }
                    Task { await playback.switchQuality(to: preset) }
                }
            )
        case .audio:
            PlayerSettingsSelectionList(
                title: "Audio",
                items: viewModel.audioTracks,
                isSelected: { viewModel.selectedAudioTrackID == $0.id },
                itemTitle: { $0.compactDisplayTitle },
                itemSubtitle: { $0.detailDisplayTitle },
                onSelect: viewModel.selectAudio
            )
        case .subtitles:
            PlayerSettingsSelectionList(
                title: "Subtitles",
                leadingOptionTitle: "Off",
                isLeadingOptionSelected: viewModel.selectedSubtitleTrackID == nil,
                onSelectLeadingOption: { viewModel.selectSubtitle(nil) },
                items: viewModel.subtitleTracks,
                isSelected: { viewModel.selectedSubtitleTrackID == $0.id },
                itemTitle: { $0.displayTitle },
                itemSubtitle: { $0.language },
                onSelect: viewModel.selectSubtitle,
                extraRows: subtitleExtraRows
            )
        case .findSubtitles:
            subtitleSearchDestination
        case .playbackInfo:
            EmptyView()
        }
    }

    private var subtitleExtraRows: [PlayerSelectionExtraRow] {
        guard subtitleSearch != nil else { return [] }
        return PlayerSubtitleExtraRows.rows(
            controller: viewModel.sidecarSubtitles,
            onFindMore: { navigationPath.append(.findSubtitles) }
        )
    }

    @ViewBuilder
    private var subtitleSearchDestination: some View {
        if let subtitleSearch {
            PlayerSubtitleSearchView(configuration: subtitleSearch) { outcome in
                subtitleSearch.onDownloaded(outcome)
                navigationPath.removeAll()
                onDismiss()
            }
        }
    }

    @ViewBuilder
    private var channelSelection: some View {
        if let live = context.liveTVContext {
            PlayerSettingsSelectionList(
                title: "Channel",
                items: live.lineup.channels,
                isSelected: { live.channel.id == $0.id },
                itemTitle: {
                    [$0.displayNumber, $0.displayTitle]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                },
                itemSubtitle: { _ in nil },
                onSelect: { channel in
                    guard channel.id != live.channel.id else { return }
                    let program = live.lineup.guide(for: channel)?.currentProgram()
                    Task {
                        await playback.playLiveTV(
                            channel: channel,
                            program: program,
                            lineup: live.lineup
                        )
                    }
                }
            )
        } else {
            ContentUnavailableView("No Channels", systemImage: "list.number")
        }
    }
}
#endif

private struct PlayerSettingsSelectionList<Item: Identifiable>: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    var leadingOptionTitle: String?
    var isLeadingOptionSelected = false
    var onSelectLeadingOption: (() -> Void)?
    let items: [Item]
    let isSelected: (Item) -> Bool
    let itemTitle: (Item) -> String
    let itemSubtitle: (Item) -> String?
    let onSelect: (Item) -> Void
    /// Rows appended below the selectable items — see `PlayerSelectionSheet`.
    var extraRows: [PlayerSelectionExtraRow] = []
    @State private var directionalFocus: PlayerSelectionTarget<Item.ID>?

    var body: some View {
        DuskDirectionalFocusScope(
            focusedID: $directionalFocus,
            groups: [.grid(selectionTargets, columnCount: 1)],
            defaultFocus: defaultDirectionalFocus,
            isEnabled: supportsDirectionalSelection,
            onActivate: activateDirectionalFocus,
            onBack: {
                dismiss()
                return true
            },
            onDirectionalBoundary: adjustDirectionalFocus
        ) {
            ScrollViewReader { proxy in
                List {
                    if let leadingOptionTitle {
                        selectionButton(
                            target: .deselection,
                            title: leadingOptionTitle,
                            subtitle: nil,
                            isSelected: isLeadingOptionSelected,
                            action: { onSelectLeadingOption?() }
                        )
                    }

                    ForEach(items) { item in
                        selectionButton(
                            target: .item(item.id),
                            title: itemTitle(item),
                            subtitle: itemSubtitle(item),
                            isSelected: isSelected(item),
                            action: { onSelect(item) }
                        )
                    }

                    ForEach(extraRows) { row in
                        extraRowView(row)
                    }
                }
                .duskScrollContentBackgroundHidden()
                .background(Color.duskBackground)
                .onChange(of: directionalFocus) { _, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
        .duskNavigationTitle(title)
        .duskNavigationBarTitleDisplayModeInline()
    }

    private var selectionTargets: [PlayerSelectionTarget<Item.ID>] {
        (leadingOptionTitle == nil ? [] : [.deselection])
            + items.map { .item($0.id) }
            + extraRows.map { .extra($0.id) }
    }

    private var defaultDirectionalFocus: PlayerSelectionTarget<Item.ID>? {
        if isLeadingOptionSelected, leadingOptionTitle != nil {
            return .deselection
        }
        if let item = items.first(where: isSelected) {
            return .item(item.id)
        }
        if leadingOptionTitle != nil {
            return .deselection
        }
        return items.first.map { .item($0.id) }
    }

    private var supportsDirectionalSelection: Bool {
        #if os(iOS)
        ProcessInfo.processInfo.isiOSAppOnMac
        #else
        false
        #endif
    }

    private func activateDirectionalFocus(_ target: PlayerSelectionTarget<Item.ID>) -> Bool {
        switch target {
        case .deselection:
            guard leadingOptionTitle != nil, let onSelectLeadingOption else { return false }
            onSelectLeadingOption()
        case let .item(itemID):
            guard let item = items.first(where: { $0.id == itemID }) else { return false }
            onSelect(item)
        case let .extra(rowID):
            guard let row = extraRows.first(where: { $0.id == rowID }) else { return false }
            row.action()
        }
        return true
    }

    private func adjustDirectionalFocus(
        _ key: KeyEquivalent,
        target: PlayerSelectionTarget<Item.ID>
    ) -> Bool {
        guard case let .extra(rowID) = target,
              let adjuster = extraRows.first(where: { $0.id == rowID })?.adjuster else {
            return false
        }

        switch key {
        case .leftArrow:
            adjuster.onDecrease()
        case .rightArrow:
            adjuster.onIncrease()
        default:
            return false
        }
        return true
    }


    @ViewBuilder
    private func extraRowView(_ row: PlayerSelectionExtraRow) -> some View {
        PlayerSelectionExtraRowView(
            row: row,
            isDirectionallyFocused: supportsDirectionalSelection && directionalFocus == .extra(row.id),
            isFocusable: !supportsDirectionalSelection
        )
        .id(PlayerSelectionTarget<Item.ID>.extra(row.id))
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowBackground(Color.duskSurface)
        .duskSuppressTVOSButtonChrome()
    }

    private func selectionButton(
        target: PlayerSelectionTarget<Item.ID>,
        title: String,
        subtitle: String?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            selectionRow(title: title, subtitle: subtitle, isSelected: isSelected)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(!supportsDirectionalSelection)
        .duskDirectionalFocusHighlight(
            directionalFocus == target,
            shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .id(target)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowBackground(Color.duskSurface)
        .duskSuppressTVOSButtonChrome()
    }

    private func selectionRow(
        title: String,
        subtitle: String?,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(Color.duskTextPrimary)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.duskTextSecondary)
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.duskAccent)
            }
        }
        .contentShape(Rectangle())
    }
}

/// One appended, non-selectable row. Kept separate from `selectionButton` so
/// the delay adjuster can carry inline controls while sharing the row chrome.
private struct PlayerSelectionExtraRowView: View {
    let row: PlayerSelectionExtraRow
    let isDirectionallyFocused: Bool
    let isFocusable: Bool

    var body: some View {
        Group {
            if let adjuster = row.adjuster {
                adjusterRow(adjuster)
            } else {
                Button(action: row.action) {
                    labelContent
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(isFocusable)
            }
        }
        .duskDirectionalFocusHighlight(
            isDirectionallyFocused,
            shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func adjusterRow(_ adjuster: PlayerSelectionExtraRow.Adjuster) -> some View {
        HStack(spacing: 12) {
            labelContent

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                adjusterButton(systemImage: "minus", action: adjuster.onDecrease)
                adjusterButton(
                    systemImage: "arrow.counterclockwise",
                    action: adjuster.onReset,
                    isEnabled: adjuster.canReset
                )
                adjusterButton(systemImage: "plus", action: adjuster.onIncrease)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .focusable(isFocusable)
    }

    private func adjusterButton(
        systemImage: String,
        action: @escaping () -> Void,
        isEnabled: Bool = true
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.duskTextPrimary)
                .frame(width: 34, height: 30)
                .background(Color.duskSurface.opacity(0.86), in: Capsule())
                .overlay {
                    Capsule().stroke(Color.duskTextSecondary.opacity(0.18), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .duskSuppressTVOSButtonChrome()
    }

    private var labelContent: some View {
        HStack(spacing: 12) {
            if let systemImage = row.systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.duskTextPrimary)
                    .frame(width: 22)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .foregroundStyle(Color.duskTextPrimary)

                if let subtitle = row.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.duskTextSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
