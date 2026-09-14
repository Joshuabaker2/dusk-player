import Foundation

@MainActor
@Observable
final class LibrariesViewModel {
    private let plexService: PlexService

    /// Read-through of the shared library-order store so every browsable list
    /// follows the order stored on the Plex account. Music and photo sections
    /// occupy slots in that order but are not browsable in Dusk, so they are
    /// filtered out here (and only here — the settings editor lists them).
    var libraries: [PlexLibrary] {
        plexService.libraryOrder.orderedSections.filter { $0.libraryType != nil }
    }

    private(set) var isLoading = false
    private(set) var error: String?

    init(plexService: PlexService) {
        self.plexService = plexService
    }

    var availableLibraryTypes: [PlexLibraryType] {
        PlexLibraryType.allCases.filter { hasLibraries(for: $0) }
    }

    func libraries(for type: PlexLibraryType) -> [PlexLibrary] {
        libraries.filter { $0.libraryType == type }
    }

    func hasLibraries(for type: PlexLibraryType) -> Bool {
        libraries.contains { $0.libraryType == type }
    }

    func loadLibraries(force: Bool = false) async {
        guard !isLoading else { return }
        guard force || libraries.isEmpty else { return }

        isLoading = true
        error = nil
        do {
            _ = try await plexService.ensureLibraryOrderLoaded(force: force)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func iconName(for library: PlexLibrary) -> String {
        library.libraryType?.systemImage ?? "folder"
    }

    func artURL(for library: PlexLibrary, width: Int, height: Int) -> URL? {
        plexService.imageURL(
            for: library.composite ?? library.art ?? library.thumb,
            width: width,
            height: height
        )
    }
}
