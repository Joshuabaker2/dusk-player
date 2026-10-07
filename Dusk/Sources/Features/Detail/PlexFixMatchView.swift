#if !os(tvOS)
import SwiftUI

/// Fix Match: re-identify a movie or show in Plex, for items Plex matched to
/// the wrong title (or never matched). Candidates show their poster and summary
/// because same-name titles from the same year are common.
///
/// The search starts from the title cleaned out of the file name, not Plex's
/// current title: when the match is wrong, the current title is the wrong one.
struct PlexFixMatchView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(\.dismiss) private var dismiss

    let details: PlexMediaDetails

    @State private var title = ""
    @State private var year = ""
    @State private var candidates: [PlexMatchCandidate] = []
    @State private var hasSearched = false
    @State private var isSearching = false
    @State private var matchingGUID: String?
    @State private var errorMessage: String?
    @State private var directionalFocus: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case title
        case year
    }

    private let searchTarget = "fix-match-search"

    var body: some View {
        NavigationStack {
            DuskDirectionalFocusScope(
                focusedID: $directionalFocus,
                groups: [.grid(directionalTargets, columnCount: 1)],
                defaultFocus: candidates.first.map { "candidate:" + $0.guid } ?? searchTarget,
                // Typing owns the keyboard while a field is focused.
                isEnabled: supportsDirectionalSelection && focusedField == nil && matchingGUID == nil,
                onActivate: activate,
                onBack: {
                    dismiss()
                    return true
                }
            ) {
                ScrollViewReader { proxy in
                    List {
                        searchSection
                        resultsSection
                    }
                    .duskScrollContentBackgroundHidden()
                    .background(Color.duskBackground)
                    .onChange(of: directionalFocus) { _, target in
                        guard let target else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
            }
            .duskNavigationTitle("Fix Match")
            .duskNavigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Color.duskBackground)
        .task {
            seedSearch()
            await search()
        }
        .alert(
            "Couldn't Fix Match",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            presenting: errorMessage
        ) { _ in
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Sections

    private var searchSection: some View {
        Section {
            TextField("Title", text: $title)
                .focused($focusedField, equals: .title)
                .submitLabel(.search)
                .onSubmit { Task { await search() } }
                .foregroundStyle(Color.duskTextPrimary)

            TextField("Year", text: $year)
                .focused($focusedField, equals: .year)
                .keyboardType(.numberPad)
                .submitLabel(.search)
                .onSubmit { Task { await search() } }
                .foregroundStyle(Color.duskTextPrimary)

            Button {
                focusedField = nil
                Task { await search() }
            } label: {
                HStack {
                    Text("Search")
                        .foregroundStyle(Color.duskAccent)
                    Spacer()
                    if isSearching {
                        ProgressView()
                            .tint(Color.duskAccent)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSearching || title.trimmingCharacters(in: .whitespaces).isEmpty)
            .focusable(!supportsDirectionalSelection)
            .duskDirectionalFocusHighlight(
                supportsDirectionalSelection && directionalFocus == searchTarget,
                shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .id(searchTarget)
        } footer: {
            Text("Changes the match on your Plex server, which updates the title, summary, cast and artwork everywhere.")
                .foregroundStyle(Color.duskTextSecondary)
        }
        .listRowBackground(Color.duskSurface)
    }

    @ViewBuilder
    private var resultsSection: some View {
        if hasSearched, !isSearching, candidates.isEmpty {
            Section {
                Text("No matches. Try a shorter title, or leave the year empty.")
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.clear)
        } else if !candidates.isEmpty {
            Section {
                ForEach(candidates) { candidate in
                    candidateRow(candidate)
                }
            }
            .listRowBackground(Color.duskSurface)
        }
    }

    private func candidateRow(_ candidate: PlexMatchCandidate) -> some View {
        Button {
            Task { await apply(candidate) }
        } label: {
            PlexMatchCandidateRow(
                candidate: candidate,
                isCurrent: target?.ratingKey == details.ratingKey
                    && details.guids.contains { $0.id == candidate.guid }
            ) {
                if matchingGUID == candidate.guid {
                    ProgressView()
                        .tint(Color.duskAccent)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(matchingGUID != nil)
        .focusable(!supportsDirectionalSelection)
        .duskDirectionalFocusHighlight(
            supportsDirectionalSelection && directionalFocus == "candidate:" + candidate.guid,
            shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .id("candidate:" + candidate.guid)
    }

    // MARK: - Actions

    private var target: PlexMatchTarget? {
        plexService.matchTarget(for: details)
    }

    private func seedSearch() {
        guard title.isEmpty else { return }
        let fileGuess = details.media.first?.parts.first?.file.flatMap(MediaTitleCleaner.guess(fromFileName:))
        // A show's files are episodes; their names lead with the show, which the
        // target's own guesses already cover.
        let guess = (details.type == .movie ? fileGuess : nil) ?? target?.guesses.first
        title = guess?.title ?? details.title
        year = (guess?.year ?? details.year).map(String.init) ?? ""
    }

    private func search() async {
        guard let target else { return }
        let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        isSearching = true
        defer {
            isSearching = false
            hasSearched = true
        }

        do {
            candidates = try await plexService.matchCandidates(
                ratingKey: target.ratingKey,
                title: query,
                year: Int(year.trimmingCharacters(in: .whitespaces)),
                agent: target.agent,
                language: target.language
            )
        } catch {
            candidates = []
            errorMessage = "Couldn't search for matches on your Plex server."
        }
    }

    private func apply(_ candidate: PlexMatchCandidate) async {
        guard let target, matchingGUID == nil else { return }
        matchingGUID = candidate.guid
        defer { matchingGUID = nil }

        do {
            // The details screen refreshes itself from the metadata revision
            // this bumps, so there is nothing to hand back.
            if try await plexService.applyMatchAndWait(
                target: target,
                candidate: candidate,
                itemRatingKey: details.ratingKey
            ) != nil {
                dismiss()
            } else {
                errorMessage = "Plex accepted the match but is still updating. It will appear shortly."
            }
        } catch {
            errorMessage = "Your Plex server didn't accept the match. Changing a match needs the server owner's account."
        }
    }

    // MARK: - Directional input

    private var supportsDirectionalSelection: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac
    }

    private var directionalTargets: [String] {
        [searchTarget] + candidates.map { "candidate:" + $0.guid }
    }

    private func activate(_ key: String) -> Bool {
        if key == searchTarget {
            Task { await search() }
            return true
        }
        guard let candidate = candidates.first(where: { "candidate:" + $0.guid == key }) else {
            return false
        }
        Task { await apply(candidate) }
        return true
    }
}
#endif
