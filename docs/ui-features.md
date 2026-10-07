# Dusk UI Feature Layer

Operational notes for agents changing SwiftUI screens, feature view models, and shared UI
in Dusk. Read this with `docs/codebase-map.md`, `STYLE.md`, and `docs/data-and-plex.md`.

## App And Navigation Shell

- `DuskApp` creates the long-lived app services and injects them into the SwiftUI
  environment: `PlexService`, `PlaybackCoordinator`, `DownloadManager`,
  `OfflinePlaybackSyncManager`, `SeerrService`, and `UserPreferences`.
- App-wide color scheme comes from `UserPreferences.appearanceMode`; app tint is
  `Color.duskAccent`, except iOS/iPadOS tab bar selection stays monochrome with
  the native `.primary` color role so the floating iPad tab bar can adapt over both
  artwork and light content backgrounds.
- `ContentView` is the account-bootstrap root gate: unauthenticated users see
  `SignInView`; signed-in Plex Home accounts are checked and, when needed, show
  `HomeUserPickerView`; only an active Home identity can discover/pick servers
  and enter `MainTabView`.
- Server discovery/refresh lives in `ContentView`; do not move connection logic into
  feature screens.
- Home selection precedes server selection because each Home identity can expose
  a different resource list. A successful switch reconstructs the main shell so
  navigation paths and feature view models cannot retain the previous user's data.
- `MainTabView` owns one `NavigationPath` per tab so tab stacks stay independent.
- Re-selecting the active tab pops that tab to root.
- When the iPad app runs on macOS, Backspace and controller B remove one element
  from the active tab's path. Left/right controller bumpers select the previous or
  next visible tab with wraparound while preserving every tab's existing path. Q/E
  are keyboard test aliases for the left/right bumpers and call the same tab-switch
  actions; they are disabled while the player is presented.
  Programmatic controller activation must call the shared `duskNavigate` environment
  action so it appends to that same path; do not introduce a nested local
  `navigationDestination(isPresented:)`, which causes one back press to unwind two
  independent navigation states.
- Available tabs are data-driven: every present and user-visible library type
  (Movies, TV Shows, Videos) plus Live TV when discovered gets its own tab in
  the user's preferred order, and
  Downloads appears only when visible and populated. Library-tab visibility and
  order are local `UserPreferences`; missing preferences preserve the original
  all-visible Movies / TV Shows / Videos / Live TV order.
- iOS/iPadOS use the modern native `Tab` API with SF Symbols and open Search
  from a circular trailing toolbar action on Home and immediately before Browse
  on each library root, leaving Search out of the tab bar. iPadOS keeps every
  remaining destination flat. On iPhone, Home plus the first three visible
  content destinations stay flat and overflow content, Downloads, and Settings
  move into `MoreView` so the tab bar stays at five items. tvOS remains flat
  with a Search tab and no Downloads tab.
- If a preference or availability change crosses the iPhone five-tab limit,
  keep the currently selected flat destination or `MoreView` mounted until the
  user selects another tab. Replacing the active container immediately tears
  down its `NavigationStack` mid-push; defer the new flat/folded layout and clear
  the retired path when leaving it.
- The tvOS tab shell forces monochrome symbols and a label-color tab bar tint
  (`Color.duskTVTabBarTint`: `TextPrimary` in Dark mode, black in Light mode).
  tvOS draws the selected, unfocused item's icon and title in the bar's tint, so
  a dark tint in Dark mode reads as black-on-black; the focused item's contrast
  against the focus plate is handled by the system, not by the tint.
- That tint is pinned on the real `UITabBar`, at launch through the appearance
  proxy and again from the shell on every update (`DuskTVTabBarTintPin`), and a
  zero-size sentinel subview inside the bar re-pins on every `tintColorDidChange`
  UIKit reports. SwiftUI's `.tint` on a tvOS `TabView` is not sticky: a bar that
  falls back to the inherited window tint picks up the global accent color and
  draws the selected tab item coral after returning from a detail screen or the
  player. The tvOS target therefore also uses a label-color global accent asset
  (`AccentColorTV`, matching `Color.duskTVTabBarTint`) so the window tint has no
  coral to hand down; SwiftUI content keeps Sunset Coral through the root
  `.tint(Color.duskAccent)` in `DuskApp`.
- `AppNavigationRoute` is the shared route enum. Add new top-level destinations there
  only when multiple features need to navigate to them.
- Use `NavigationLink(value:)` with `AppNavigationRoute` for media/person/library flows.
- Attach `.duskAppNavigationDestinations()` inside each tab `NavigationStack`; it maps
  routes to concrete destination views with environment services.
- Detail routing enters through `MediaDetailDestinationView`, which dispatches by
  `PlexMediaType` and passes download/offline context through.
- Playback presentation is centralized in `MainTabView` through
  `PlaybackCoordinator.showPlayer` and `PlayerView`; feature screens should call
  `playback.play(...)` or `playback.playVersion(...)`, not present the player.

## Shared UI Primitives

- Prefer shared primitives before adding feature-local copies.
- Loading, empty, and retry states belong to `FeatureLoadingView`,
  `FeatureEmptyStateView`, and `FeatureErrorView`.
- `FeatureErrorView` shows Retry for ordinary failures. Messages that mean the
  Plex account session is dead (`PlexServiceError.unauthorized` /
  `.notAuthenticated`) replace Retry with Sign In, which calls `signOut()` so
  `ContentView` presents `SignInView`. Do not add a local retry button for those
  errors. Successful re-auth is a new session; it does not resume the failed
  screen or playback.
- Poster UI is layered: `PosterArtwork`, `PosterCardText`, `PosterCard`,
  `PosterNavigationCard`, and `PosterActionCard`.
- Fully watched items (e.g. fully watched seasons) pass `isWatched` to the poster
  card to show a checkmark next to the title; suppress the progress bar in that
  case (pass `progress: nil`) so completion reads as the checkmark, not a full bar.
  Partial progress still renders the bar (`DuskPosterMetrics.posterProgressBarHeight`).
- Use `PlexItemPosterCarouselSection` for horizontal shelves and
  `PlexItemPosterGrid` for grids. They already handle image sizing, context menus,
  progress, and route creation. Both take `imageAspectRatio` (default 2:3); pass
  `16.0/9.0` for clip content so the requested transcode size matches the display
  aspect — a 2:3 request would be cropped server-side.
- On iOS/iPadOS, shared poster cards normally use SwiftUI focus. When the iPad app
  runs on a Mac, use `DuskDirectionalFocusScope` for keyboard/controller navigation.
  A screen declares ordered `single`, `row`, or `grid` focus groups and supplies one
  activation closure; the scope owns default/invalid focus repair, arrow and D-pad
  movement, edge-input consumption, and Return/keypad Enter/Space/controller A
  activation through the same selection action.
  The iPad-on-Mac bridge registers with `DuskControllerInputRouter`; it never
  installs hardware callbacks itself. The router selects visible input contexts
  and yields to sheets. D-pad and left-stick directions move immediately, repeat
  after 400 ms at 120 ms intervals, and stop on release/cancellation. A/B and
  shoulder actions do not repeat. Keyboard arrows share the same repeat path.
  `duskDirectionalFocusHighlight` owns the shared coral inset border and
  accessibility-selected state. Its `InsettableShape` must match the control's
  actual shape/radius. It uses `strokeBorder` inside the target bounds, with no
  negative padding, scaling, or outer glow that list cells/toolbars can clip.
  Poster selection is drawn on `PosterArtwork` with its own 16pt radius, not
  around the combined artwork/title stack. Home, library recommendation shelves and grids,
  movie/show/season/episode details, episode strips, and iOS Settings all use this
  same primitive; do not add screen-local key
  handlers or one input responder per carousel. Home declares the cinematic hero
  Play action first, followed by its poster shelves. Show and episode details declare
  Play first, followed by the season grid or episode row, so Play is the default and
  Up/Down crosses between the action and content naturally. A scope may supply a
  boundary action when an edge has screen meaning: Home uses Left/Right on the hero
  Play target to request the previous/next cinematic slide. Callers still scroll to
  their focused target because vertical and horizontal scroll containers are layout
  concerns. `MediaCarousel` disables scroll clipping in this environment so the
  selection ring and shadow remain intact at shelf edges. Do not bind the same links
  to SwiftUI focus while the custom scope is active; competing first-responder
  ownership causes vertical arrows to scroll independently of the selection.
- Directional selection survives temporary suspension (pushed details, tabs,
  player covers, and sheets), with invalid targets repaired when content changes.
  Vertical transitions retain the preferred column across narrower action rows.
  Home/library graphs include Search and each rendered Show All tile; Home's
  Live TV shelf participates as a program row. Carousel callers pass
  `directionalShowAllIsSelected` so the trailing tile scrolls into view. Library
  Browse has one graph for Genre, Sort, and posters; A opens a choice sheet for
  its filters, and the grid's nested input scope is disabled on that page.
- A page containing `PlexItemPosterGrid` must apply
  `.duskScrollsDirectionalFocus()` to its scroll container. The grid uses the
  supplied environment action and stable item IDs to bring selected rows into
  view, including lazy rows that trigger pagination.
- Clip rendering is item-driven: `PlexItem.isClip` (item `subtype == "clip"`) and
  the `Collection.isAllClips` helper decide when a row/grid renders 16:9 with
  `DuskPosterMetrics.videoCarouselWidth`/`videoGridPreferredWidth`. Clip card
  subtitles show the full localized upload date and compact duration via the
  clip-aware `standardPosterSubtitle`; uploads from the last week also prefix
  relative context (for example, `2 days ago · 17 Jul 2026 · 12 min`).
- Context menus for partially watched playable items should expose both watch-state
  endpoints: mark watched and mark unwatched. Do not collapse partial progress into
  a single toggle action.
- Use `MediaCarousel` for generic horizontal sections. It renders only the section
  title; it has no header accessory slot, so do not reintroduce buttons beside the
  title. Its horizontal padding can be overridden when a page needs its shelves to
  share the system navigation title's leading edge.
- A shelf's "Show all" destination is `ShowAllCarouselTile`, rendered by
  `PlexItemPosterCarouselSection` / `PlexItemActionCarouselSection` as the **last
  card** of the shelf on **every** platform — a dashed card sized like the shelf's
  artwork (`imageAspectRatio` aware), so the destination reads as content instead of
  a cramped header button. Pass `showAllRoute` only when the shelf is actually
  truncated; a nil route simply omits the tile.
- Use `AdaptivePosterGridLayout.make(...)` for responsive poster grids. Do not hand-roll
  column math in feature files.
- Use `DuskPosterMetrics` for platform-sensitive poster widths, grid spacing,
  horizontal padding, detail padding, and text fonts. On the macOS
  Designed-for-iPad runtime, poster grids, detail grids, and carousel cards use
  larger desktop-scale widths; keep the compact iPhone/iPad values unchanged.
  Home uses the shared carousel width too: 260pt on Mac (twice the former
  hardcoded 130pt), 130pt on iPhone/iPad, and 232pt on tvOS.
  Poster carousels and grids accept `displayTitle` for shelves that represent a
  series with an episode; keep the episode itself as the navigation/context-menu item.
- Use `MediaTextFormatter` for duration, season/episode labels, counts, progress,
  media type icons, air dates, and playback version labels.
- Use `PlexItemPresentation` helpers for standard poster subtitles, continue-watching
  labels, poster progress, and image URL selection.
- Use `DuskAsyncImage` for Plex artwork. It integrates app image caching and can route
  Plex image requests through `PlexService` when needed.
  Its optional `artworkRequest` carries exact media identity for Cinemeta enrichment;
  keep the original URL as the Plex fallback. Shared poster collections supply this
  context automatically, and Plex search cards supply it from `SearchMediaResult`.
  Home backdrop prefetch and async loading share the same source choice, and switching
  sources clears Home's preloaded backdrops so old Plex images cannot win the render.
- Use `DetailHeroBackdrop` with `DuskHeroBackdropOverlay` for full-bleed hero artwork,
  and always apply `duskHeroBackdropBottomFade()` to the backdrop + overlay stack.
  The overlay owns the shared top and leading scrims; the bottom fade into the page
  is platform-split: on iOS the overlay paints a `Color.duskBackground` gradient and
  cap, on tvOS the modifier instead masks the hero to fully transparent so the page
  background underneath is the only fill at the hero boundary. Pass `.compact` to the
  modifier for a shorter, lighter tvOS fade that reveals more of the backdrop (the home
  cinematic hero banner uses this); detail heroes keep the default `.standard` fade.
  On iOS the overlay's own scrim strength is selectable via its `style`: the home hero
  uses `.soft` on wide layouts and `.standard` on compact ones; the
  movie/show/season/episode detail heroes also pass `.soft` to hold the darkening
  and bottom fade off until the lower third so more of the
  backdrop reads through behind the title block. `style` is iOS-only — tvOS always
  renders the full-strength vertical scrim regardless.
  Never paint `Color.duskBackground` (gradient or solid) inside a hero subtree on
  tvOS: real Apple TV HDR output resolves hero-subtree fills and the plain page
  background through different color pipelines, so two stacked fills of the same
  color still meet with a visible seam and gray mismatch on hardware even though
  every simulator renders them identically. Fading the hero to zero alpha is the
  only seam-proof topology.
  When a detail hero swaps artwork from focus changes, opt into retaining the previous
  backdrop while the next one loads instead of clearing the image.
- When the iOS Home cinematic hero is visible, keep the tab bar color scheme dark.
  The floating iPad tab bar can sit over hero artwork, so its selected label must
  resolve against the tab bar material instead of the page's light appearance.
- On tvOS, poster, episode, and cast artwork controls should use
  `duskSuppressTVOSButtonChrome()` plus `duskTVOSFocusEffectShape`. Avoid SwiftUI's
  `.plain`, `.borderless`, `.glass`, and `.card` button styles directly here because
  real Apple TV hardware can draw gray/white system focus plates. When a poster card
  has labels below the artwork, keep the artwork as the actual control but apply
  `duskTVOSFocusedScale` to the outer card so the full poster container grows with
  a tight neutral white glow and without gaining a button background.
- Use platform helpers in `View+Platform.swift` instead of scattering `#if os(tvOS)`:
  `duskNavigationTitle`, title display modes, list background/separator suppression,
  status-bar helpers, tvOS button chrome suppression, and tvOS focus effect shape.

## Home

- `HomeView` is the tab root. It owns `HomeViewModel`, handles loading/error state,
  refreshes on appear, scene activation, and player dismissal, then delegates layout to
  `HomeIOSView` or `HomeTVView`.
- The cinematic hero always resets to its first item after player dismissal, app
  activation, Home-tab re-entry, or a change to the hero item order. Keep the explicit
  reset revision flowing from `HomeView` through both platform shells so a Plex refresh
  cannot preserve a stale selection after Continue Watching reorders.
- `HomeViewModel` owns ordinary Plex Home calls. The separate shared
  `LiveTVViewModel` owns the optional, non-blocking Live TV Home shelf.
- `HomeView` keys its load context by both the active Plex Home profile and server,
  and installs a fresh `HomeViewModel` whenever that context task starts. Keep the
  profile in this identity: Home users commonly share a server ID, and retaining
  the outgoing model can let its in-flight load suppress the incoming user's load.
- Home data combines global hubs from `getHubs()`, continue watching from
  `getContinueWatching()`, and personalized shelves from `HomeRecommendationEngine`.
- `LiveTVHomeShelf` adds currently airing channels when Live TV is available and
  `UserPreferences.showsLiveTVOnHome` (Settings › Home › Show Live TV, off by
  default) is on. When off, Home neither renders the shelf nor requests the
  now-playing lineup; the Live TV navigation tab is unaffected. Its
  discovery/load failure must not replace or delay normal Home content.
- Home publishes the base hub and continue-watching payload first, then expands
  Recently Added hubs and loads personalized shelves through cancellable follow-up
  tasks. Keep this two-phase behavior so expensive recommendation work does not block
  the first visible home content.
- Continue-watching items drive `HomeCinematicHero`.
- Home filters playlist/music/unknown content and hides Plex "continue watching/on deck"
  hubs so the custom continue-watching flow is not duplicated. That rule lives in
  `HomeHubFilter` (`HomeHubFilter.swift`).
- Home's arrangement is fixed and identical on both platforms: the cinematic hero,
  the Live TV shelf (when enabled), the Plex hubs, then the personalized shelves. `HomeIOSView` and
  `HomeTVView` each render that sequence directly. There is no user-editable Home
  layout; do not reintroduce one.
- Within the hubs, `HomeHubArrangement.arrange(hubs:libraryOrder:)` regroups the rows
  so each library's hubs appear in the order the account gives that library
  (`PlexHub.resolvedLibrarySectionID`, falling back to the numeric suffix of
  `hubIdentifier`). It is a pure permutation — global rows first, then one block per
  library in library order, then rows whose section is unknown. `libraryOrder` must be
  built from *every* section, including music and photo, or the blocks drift.
- Recently Added hubs are expanded through `getHubItems(...)` so shelf limits are
  intentional and "Show all" can point to `.hub`.
  TV recent hubs instead use `getRecentlyAddedTVItems(...)`: preserve the hub's
  recently-added show order and resolve each series through its `allLeaves` endpoint
  to its most recently released unwatched episode (season/episode order breaks
  same-day ties). Partially watched episodes remain eligible. Base payloads use
  `groupedRecentTVItems` to retain whole-show and season entries during loading;
  never apply the episode-only selector to that mixed payload. A failed series lookup
  retains its original navigable entry without dropping the rest of the shelf.
  Pagination continues past duplicates and fully watched shows to fill the shelf.
  TV library shelves and the hub's "Show all" grid use the same rule. Cards show the series
  title and the selected episode's S/E label, and open that episode's details.
  The TV "Show all" tile uses the grouped count (expansion requests one extra show),
  rather than Plex's raw episode count.
- `HomeCinematicHero` owns hero rotation, drag navigation on iOS, tvOS remote
  swipe capture, image preloading, title-logo fallback, pager state, and motion
  reduction. iOS enables automatic rotation (`autoRotates: true`): the hero advances
  every 7s and the pager pills animate a fill that tracks the timer. The hero pauses
  rotation while `PlaybackCoordinator.showPlayer` is true and restarts it fresh on
  return, so opening the player no longer advances the hero in the background.
  Rotation also respects Reduce Motion, scene phase, and drag interaction.
  **tvOS keeps `autoRotates: false`** — the focusable play button lives inside the
  per-item hero slide (keyed by `ratingKey`), so an unattended rotation tears down the
  view that owns the `.heroPrimaryAction` focus binding. Because the Home tab stays
  alive behind other tabs, a background rotation leaves that binding detached, and
  returning to Home and pressing down from the tab bar drops focus into nothing (the
  cursor vanishes and nothing is selectable). Do not re-enable tvOS rotation without
  first moving the play button to a stable focusable view outside the sliding slides.
  Discrete hero moves must mount the incoming slide at its off-screen offset before
  advancing animation progress, and overlapping remote commands are queued instead of
  replacing an in-flight slide. Publish prefetched artwork as each request completes;
  waiting for the entire batch lets one slow image make other slides pop in late.
  Extend it carefully; it is stateful and timing-sensitive.
- Home hero artwork requests `fitWithinSize: true` and ordinary Cinemeta/Plex
  backgrounds; Home no longer requests the experimental title-bearing wide strips.
  Landscape windows at least 850pt wide (aspect at least 1.2:1) use
  `HomeHeroMontage`: one dominant image and up to four distinct angled panels.
  Its normalized panel vertices define both each tile's parent rectangle and clip
  shape. Two/three/four-image layouts adapt instead of repeating a source to fill
  empty panels; a single image fits in the right-hand region. The main tile crops
  from the top to preserve heads; smaller tiles crop within their own shapes.
  Hero height is 46% of the viewport, bounded to 360...540pt plus the top inset;
  captions occupy up to 30% of the width. Phones and narrow/portrait windows retain
  the existing centered/aspect-fit presentation and platform height bounds.
- `HomeViewModel.heroFrameURLs` reads the current/nearby movie or episode's Plex details,
  checks `Part.indexes` for `sd`, and requests four individual timestamp images.
  Unfinished titles sample the opening/seen portion; watched titles can sample
  the broader runtime. No video stream, complete BIF index, seek, transcode or
  thumbnail-generation request is used. Missing/broken previews fall back to
  landscape movie artwork (Fanart.tv) or the current/previously watched episode
  stills and TVmaze backgrounds. Cinemeta resolves exact provider identity.
  `HomeCinematicHero` preloads the selected slide and its previous/next neighbors
  (wrapping with the carousel), plus the outgoing/incoming slide during a jump.
  Main backdrops, logos and galleries share this window of at most four items;
  completed neighboring galleries survive ordinary navigation. Gallery loads run
  concurrently, prioritizing the selected slide. The main image and final panels
  are published together: an enabled montage shows a native loading indicator
  until its lookup completes, never an interim single-image layout. A confirmed
  empty gallery can use the final single-image fallback; a failed main image shows
  artwork unavailable rather than spinning forever. Source ordering is preserved,
  blank/repeated images are filtered, and stale tasks cannot publish.
  ImageIO downsamples gallery images to at most
  1100px; image memory is bounded by decoded cost as well as entry count.
- Settings exposes Movie/TV Hero Montage toggles, retaining the former wide-banner
  preference keys and saved choices. Plex frames work with Cinemeta disabled;
  external gallery requests require Cinemeta enabled. Disabling a montage leaves
  a single-image layout. Captions/actions/pager retain their alignment and the
  existing rotation, drag, keyboard/controller and tvOS focus behavior. Mac focus
  returning to Play scrolls to the hero's top. Detail heroes retain their layout.
- On the macOS Designed-for-iPad runtime, Home keeps Play/Resume selected by default.
  Left/Right while that hero action is selected requests the previous/next hero with
  the same queued transition path used by drag/remote navigation; Down enters the
  first poster shelf. Do not implement this as a second carousel state machine.
- On tvOS, `HomeCinematicHero` pixel-aligns its render size and caps image dynamic
  range to standard to avoid real-device HDR/SDR seams between the backdrop fade and
  the shelves below.
- On tvOS, the title/logo block, metadata, button and pager retain their compact
  placement and the first shelf remains discoverable beneath the hero. Normal
  Down focus movement reaches the shelves. Keep the controls restrained so the
  hero reads cinematic instead of crowded.
- On iOS the home hero play button uses `homeHeroNativeButtonStyle()` (prominent,
  `Color.primary`-tinted Liquid Glass that contrasts the artwork) with
  `HomeHeroActionButtonLabel(fillsWidth: true)`, sized as a wide, short pill
  (≈240pt iPhone / ≈300pt iPad). Keep it consistent with the detail primary button
  (`STYLE.md` §3.3); do not fill it with the coral accent.
- `HomeIOSView` and `HomeTVView` should stay composition shells. Keep Plex data rules in
  `HomeViewModel`, not in platform views.
- Use `HomeItemContextMenu` for hero context actions. It already exposes mark watched,
  details, season, and show routes when available. Its optional
  `onRemoveFromContinueWatching` adds Plex's "Remove from Continue Watching" action
  (server `PUT /actions/removeFromContinueWatching`); the hero supplies it because its
  items are always the Continue Watching hub. `HomeViewModel.removeFromContinueWatching`
  drops the item optimistically, then reloads to reconcile.
- `HomeHubItemsView` is the full "show all" grid for hub contents. It has its own small
  view model and uses the shared poster grid; all-clip hubs render it 16:9.

### Library Order

- `Settings › Navigation › Library Order` opens `LibraryOrderSettingsView` on every
  platform. It edits the order of the *connected server's* libraries, which is an
  account-level Plex setting rather than a Dusk preference: the same order drives the
  Plex Web sidebar and the other Plex apps signed in as this user.
- The screen lists **every** section of the server, music and photo included, even
  though Dusk cannot browse those. They occupy slots in the account's order, so
  omitting them would silently move them when the list is written back.
- iOS/iPadOS use native list editing (`EditButton` + `onMove`). tvOS uses a position
  menu per row (`TVSettingsMenuRow`), the same pattern as Navigation Tabs, with
  formatted ordinal labels so the list is not capped at a handful of names.
  **The previous focus-driven pick-up (the old Home layout editor) was removed and
  must not come back.** It was unusable on a real remote: directional commands only
  reach an `onMoveCommand` handler when the focus engine finds no candidate, and the
  tvOS tab bar sits above this screen, so a row moved down but not up.
- Writes are debounced 1s and coalesced, so walking a library through six slots is one
  account write, not six. `onDisappear` flushes a debounce that is still counting down.
- A failed write reverts the list to `PlexService.libraryOrder.orderedSections` and
  shows an inline message; showing the rejected order would lie about what the other
  Plex apps will do. A failed load shows `FeatureErrorView` with Retry.
- The order is read and written through `PlexService`; the view model never talks to
  plex.tv itself. Storage format and traps: `docs/data-and-plex.md`.
- Clips never enter the cinematic hero rotation (`HomeViewModel.heroItems()` filters
  `isClip` — frame grabs read poorly full-bleed). They stay visible in hub rows, where
  an all-clip hub (`isVideoHub`) renders as a 16:9 carousel.

## Libraries

- `LibrariesViewModel` groups Plex libraries by `PlexLibraryType`. Its `libraries`
  reads through `PlexService.libraryOrder.orderedSections`, so the library list and the
  library tabs follow the account's library order, not raw `/library/sections` order.
- `MainTabView` reuses a single `LibrariesViewModel` to decide tabs and feed library
  screens. Avoid each tab independently discovering libraries.
- `LibrariesView` is the direct Movies/Shows/Videos tab wrapper. If exactly one
  matching library exists, it goes straight to `LibraryRecommendationsView`. (The old
  combined `LibrariesHubView` tab is retired; every type gets its own tab.)
- `LibraryRecommendationsViewModel` is the library-scoped home equivalent:
  `getLibraryHubs(...)`, continue-watching hub extraction, recently-added expansion,
  and personalized shelves from `LibraryRecommendationEngine`.
- On the macOS Designed-for-iPad runtime, `LibraryRecommendationsView` declares one
  shared directional row per visible shelf. Its default is the first content card;
  Left/Right moves inside a shelf, Up/Down preserves the nearest column across shelves,
  and Return/controller A plays Continue Watching cards or opens other media details.
  The Browse Library toolbar action is the single group above the first shelf. Disable
  the scope when its tab is not selected or its navigation path is not at the root.
- `.video` libraries never run the genre engine. Their shelves come from
  `LibraryVideoShelfLoader`: per-channel rows (first ~6 collections via
  `getLibraryCollections`, items sorted by release date) and a day-seeded
  "Rediscover" row of unwatched items. Row order: Continue Watching, prioritized
  hubs, secondary hubs, channel rows, Rediscover — all 16:9.
- `LibraryItemsView` is the browse grid for a concrete library, genre, or collection
  route; `.video` libraries use the 16:9 grid metrics.
- `LibraryItemsViewModel` handles pagination, sort, genre selection, optional local
  genre filtering, and optional collection scoping (`LibraryCollectionItemsView`
  delegates to it). Sort options are per-kind via `LibrarySortOption.options(for:)`;
  video libraries default to Release Date (newest).
- Use `LibraryGenreSupport` for Plex genre filter discovery, normalization, URL
  parameter extraction, and fallback matching. Do not compare genre strings ad hoc.
- `LibraryItemsViewModel` uses a `queryGeneration` guard so stale async page loads do
  not mutate current results. Preserve this pattern when adding filters.
- Infinite scroll is triggered from `PlexItemPosterGrid.onItemAppear`; keep pagination
  logic in the view model.

## Detail Screens

- Detail entry is split by domain: movie, show, season, episode, video (clip), and
  actor detail views each have their own `@Observable` model.
- Clips route to `VideoDetailView` via `.video`/`.downloadedVideo` routes
  (`AppNavigationRoute.destination(for:)` branches on `item.isClip`) — never to
  `MovieDetailView`. It is a trimmed movie page: hero metadata line is
  "channel · upload date · duration", no cast/ratings sections, plus a
  "More from {channel}" 16:9 row resolved from the item's first Collection tag.
- Detail views own screen layout; detail view models own Plex fetches, offline fallback,
  watch-state mutations, image URL selection, and computed display state.
- Shared detail UI lives in `DetailSharedViews.swift` only when reused across detail
  screens.
- Mac heroes and shelves share a 56pt horizontal content gutter through
  `DuskPosterMetrics.detailHorizontalPadding` / `carouselHorizontalPadding`.
  Home captions/pager and detail title/metadata/action columns align with shelf
  headings and their first cards. Apply padding to content, keeping backdrops
  full bleed. Phone/iPad and tvOS retain their existing metrics.
- Use `DetailHeroSection` for cinematic detail headers. It owns the backdrop
  gradient/scrim, title artwork, supertitle/subtitle/action slots, an optional
  `descriptionText`, and safe-area offset. There is **no poster on any platform**:
  iPhone centers one column (title, metadata, actions); iPad uses two columns
  (left: title + actions, right: marker/metadata + `descriptionText`); tvOS is a
  left-aligned column with the action row beneath. Use
  `detailHeroContentAlignment(for:)` / `detailHeroTextAlignment(for:)` to center
  hero text on iPhone, and `detailShowsSynopsisBelowHero(for:)` to drop the
  below-hero synopsis section on iPad (the hero's right column shows it there).
- Detail hero actions share one button system across all platforms (see
  `STYLE.md` §3.3). The primary uses `detailHeroNativePrimaryButtonStyle()` —
  prominent, `Color.primary`-tinted Liquid Glass for contrast (dark-on-light /
  light-on-dark) with a `Color.duskPrimaryActionLabel` label; on Show/Season it
  reads just "Play" / "Resume" (`playButtonShortLabel`), never the target episode.
  Secondary actions (download, watched, go-to-show/season) are **icon-only**
  everywhere via `DetailHeroSecondaryIconLabel` + `detailHeroNativeSecondaryButtonStyle()`
  with an `.accessibilityLabel` (capsule pills on iOS, circles on tvOS). On iOS wrap
  the action block in `detailHeroActionStackFrame(isCompactPhone:)` (iPhone ≈60%
  centered, iPad fills the hero's left column); tvOS lays the icons out to the right
  of the primary. Movie/Show/Season/Episode all expose a watched toggle; Show/Season
  toggle the whole show/season. Do not fill primary actions with `Color.duskAccent`.
- On iOS/iPadOS movie and episode details with resume progress, a full-width Restart
  Movie/Restart Episode secondary action sits directly below Play/Resume and calls
  `PlaybackCoordinator.playFromStart(...)`. In the macOS directional group, Play is
  still the default, Down selects Restart, and another Down continues into any episode
  collection below the hero. With no progress, omit Restart from both the UI and focus
  group so Down skips directly to the next meaningful target.
- On tvOS, keep focusable detail rows in separate `.focusSection()` groups. Hero
  actions, expandable summaries, season/episode grids, and cast shelves should move
  vertically to the next visible row instead of letting the focus engine skip to a
  lower but more horizontally aligned item.
- Mac cast shelves use 200pt square portraits, 24pt spacing, headline actor
  names and subheadline roles with two reserved lines each. `DuskPosterMetrics`
  owns the cast sizes/spacing; `ActorCreditCard` requests artwork at display
  scale so the larger portraits stay sharp on Retina screens. The Cast heading
  uses Title 2 on Mac; phone/iPad and tvOS keep their existing cast metrics.
- Detail screens use hidden inline navigation bars over hero artwork. Keep
  `.toolbarColorScheme(.dark, for: .navigationBar)` and hidden toolbar backgrounds unless
  the screen is no longer hero-led.
- Detail screens refresh after player dismissal and scene activation to pick up watch
  progress.
- Episode detail renders Episodes, a horizontal Seasons preview row, then Cast
  on Mac. Season cards match the episode cards' landscape artwork, spacing,
  typography and focus border, and show a Selected badge plus episode count.
  With Cinemeta artwork enabled, previews use a representative episode still
  from the matching season. Plex fallback prefers a still from that season's
  loaded/cached episodes, then lazily loads visible seasons' episodes, then uses
  the season's own poster/art; a shared show backdrop is not preferred.
  Selecting a season updates the Episodes row above it without a modal or a
  navigation push; selecting an episode opens its details. The hero and Play
  remain attached to the displayed episode. Both Mac rows use 400pt cards and
  Retina-sized image requests; `DuskPosterMetrics` owns width and spacing.
  Mac episode cards include up to three lines of synopsis directly beneath the
  title, followed by episode number/date metadata. The episode hero requests
  uncropped Plex artwork (`fitWithinSize`) and opts into top-aligned rendering
  via `DetailHeroSection.backdropImageAlignment` so the short, wide banner does
  not center-crop heads out of the frame.
  The directional graph follows hero actions → episodes → seasons, with stable
  per-row scroll IDs and horizontal scrolling to the focused season.
- `EpisodeDetailViewModel` loads the show's Plex seasons alongside the selected
  season's episodes, using download metadata caches as fallback. Selection
  survives refreshes; a request generation prevents a slower, previous season
  response from overwriting a newer selection. Loading/empty/retry states stay
  in the Episodes row so the Seasons row remains reachable after a failed request.

- `MovieDetailViewModel` handles movie metadata, media info, resume position, watched
  state, and offline movie metadata banners.
- `ShowDetailViewModel` loads show details, seasons, next-episode metadata, season
  availability badges, and show-level offline messaging.
- `SeasonDetailViewModel` loads season details and episodes, computes the next episode,
  sorts offline-available episodes first when appropriate, and records offline watch
  mutations.
- `SeasonDetailView` uses a tvOS-only horizontal episode shelf. Each card shows the
  episode title with a "Season X · Episode N" subtitle and a watched checkmark beside
  the title (via the shared `PosterCardText`), matching the season cards; partially
  watched episodes keep the in-poster progress bar. The tvOS season hero mirrors the
  show hero: the show's clear-logo is the title artwork (`showTitleLogoURL`, falling
  back to the show name), so it drops the iOS show-name supertitle link. The focused
  episode's name rides just beneath the logo as a "somewhat prominent" title accessory,
  with its "Episode N · 45 min · air date" tagline and summary in the subtitle slot.
  Focused episode cards update the hero artwork, that episode title/metadata block, and
  the episode cast row inside stable-height regions, and the committed focus is debounced
  so rapid remote navigation does not shift the scroll position; selecting a tvOS episode
  card starts playback directly while iOS keeps the vertical episode list and
  detail-navigation behavior. On the macOS Designed-for-iPad runtime, the season Play
  action is the default directional target; Down enters the ordered vertical episode
  list, Up returns to Play, and Return/controller A on an episode opens its detail page.
- `EpisodeDetailViewModel` handles episode metadata, parent show/season links, watch
  toggles, offline availability, and the parent season's sibling episodes in stable
  episode-number order. On iOS, `EpisodeDetailView` shows those siblings in a horizontal
  season strip with the current episode marked. The iPad-on-Mac directional bridge owns
  its coral selection ring, consumes left/right keyboard or controller D-pad input,
  scrolls the selected card into view, and opens it with Return or controller A/Select.
- `ActorDetailViewModel` loads a person plus filmography by searching Plex for exact role
  matches. Keep this search behavior local to actor detail unless Plex gets a stronger
  people endpoint.
- Use `PlayVersionContextMenu` for alternate media versions; it filters out unplayable
  versions with no parts.
- Use `DownloadActionButton` and `DownloadContextMenuContent` from the downloads
  feature for download actions. Do not duplicate download state UI in detail screens.
- Offline-capable detail models may show cached metadata before network refresh. Preserve
  `isUsingCachedData`, offline-fallback state, `offlineStateVersion`, and
  `OfflinePlaybackSyncManager` checks when changing watched/progress behavior.
- Some show/season loading is intentionally sequential to avoid async-let runtime aborts
  during transient context-menu navigation lifetimes. Do not "optimize" it back to
  `async let` without reproducing that scenario.

## Live TV

- `MainTabView` owns one shared `LiveTVViewModel` for availability, the tab,
  `MoreView`, and the Home shelf. Do not discover providers independently per
  surface.
- `LiveTVView` offers yesterday through seven days ahead, channel/program
  artwork, current-program progress, schedule details, and Watch actions only
  for currently airing programs. Past entries remain inspectable but are not
  presented as recordings.
- The player gear menu exposes channel switching on iOS/iPadOS and tvOS. The
  live seek bar shows LIVE or the time behind live and provides Go Live; all
  forward movement is clamped to the HLS edge.

## Search And Settings

- `SearchView` is a thin tab-root wrapper (`NavigationStack` + destinations) around
  `SearchRootContent`, which owns the view model, searchable field, and results; the
  split lets iPhone/iPad toolbar actions push Search without a nested stack.
  Settings and Downloads follow the same wrapper/`*RootContent` pattern.
  All-clip result groups render 16:9.
- Search is debounced in the view model with a cancellable `Task`; views only bind the
  query and render grouped results.
- When Seerr is connected, search also performs an additive Seerr discovery
  request. Plex groups publish first; external movies/shows are deduplicated and
  appended with request-state badges. A Seerr failure stays silent and never
  breaks Plex search.
- Presentation is platform-adaptive so search feels native everywhere. tvOS and iPad
  (`userInterfaceIdiom == .pad`) render each result group as a
  `PlexItemPosterCarouselSection` (the same poster carousels Home uses for hubs); iPhone
  renders each group as a titled `PlexItemPosterGrid` section (matching the library grid).
  Plex `/hubs/search` returns one hub per media type, which maps cleanly onto a carousel
  row or a grid section.
- All platforms reuse the shared `FeatureStateViews` for empty/loading/error/no-result
  states through one `searchResults(_:content:)` wrapper, so state reporting stays uniform.
- Search results route through `AppNavigationRoute.destination(for:)` so people, movies,
  shows, seasons, and episodes stay consistent with the rest of the app.
- Seerr cards instead use dedicated request-only routes. Never put them through
  Plex detail routes, playback, downloads, or watch-state actions.
- `SettingsView` selects the platform shell. Shared sheet/navigation chrome is in
  `SettingsContainer`.
- The Integrations section links to `SeerrSettingsView`. Both platforms accept
  only a server URL and connect using the active Plex identity; tvOS uses native
  keyboard/Remote input rather than a browser login.
- `SettingsViewModel` is for transient settings UI state: the silently refreshed
  server list, server picker, Home-user picker presentation, image cache status,
  app version, and server/user switching.
- Persistent settings live in `UserPreferences`, not `SettingsViewModel`.
- Settings → Navigation holds the two ordering screens, and they are deliberately
  different in scope. Navigation Tabs controls the visibility and order of Movies,
  TV Shows, Videos, and Live TV; it is device-local `UserPreferences`. Library Order
  controls the order of the server's individual libraries; it is stored on the Plex
  account (see "Library Order"). Both use native list editing on iOS/iPadOS and
  position menus on tvOS.
- For Navigation Tabs, hidden types stay in the saved order so restoring one puts it
  back where the user placed it.
- `UserPreferences` is `@Observable`, environment-injected, and backed by `UserDefaults`.
  Add new device-local user-facing preferences there with a key, default loading, and
  persistence. A setting Plex already models for the account belongs in `PlexService`
  instead, like library order.
- `forceAVPlayer` and `forceVLCKit` are mutually exclusive in `UserPreferences`; do not
  bypass those setters.
- `videoEnhancementMode` is a persisted playback preference with Auto, On, and
  Off settings. It affects local rendering only, must not request Plex
  transcoding, and must not alter startup quality. Its per-platform default
  lives in `VideoEnhancementMode.defaultForPlatform` — Auto on Apple TV, Off on
  battery-powered devices.
- Playback Info exposes Video Enhancement state and detail rows so AVPlayer and
  VLCKit sessions can explain whether enhancement is active, waiting for a
  frame, disabled by preference, or unavailable for a stream/runtime reason.
- `SettingsSupport` owns shared settings copy, URLs, language options, and bindings.
  Subtitle and audio pickers share `CommonLanguage`; adding an ISO 639-1 case there
  is enough for both platforms. Playback matching then canonicalizes Plex/VLCKit
  ISO 639-2 codes (`rum`/`ron` → `ro`) in `PlayerViewModel.normalizedLanguageCode`.
- Picking a subtitle enables full subtitles on subsequent titles, with English
  as the fallback when the track has no language metadata. Missing subtitles
  are searched through Plex in the background and ranked by download count;
  see the automatic subtitle search flow in `playback.md`.
- Both settings pages lead with a supporter row (thank-you state for supporters),
  followed by Plex Home when applicable and Plex Server when the active user can
  access multiple servers. Opening Settings refreshes the server list silently;
  the existing app-start connection refresh remains separate. Everyday playback
  and appearance settings follow, while engine overrides, storage, About, and
  Account stay lower on the page. AI Upscaling is a normal Playback Default;
  Playback Advanced is reserved for forced engine selection. The iOS Appearance
  section has an App Icon row opening `AppIconPickerView`. The supporter tier
  itself (StoreKit products, status rules, the iOS/iPadOS prompt ladder, alternate
  icons) is documented in `supporter.md`; tvOS only exposes supporter purchases
  through Settings.
- Player Quality lives in the in-player gear menu, not global Settings. It is a
  per-session manual action and must not create a persisted default that starts
  future sessions transcoded.
- Settings → Artwork → Cinemeta Artwork is a device-local, on-by-default toggle
  on iOS/iPadOS and tvOS. It needs no account, key, or Seerr setup. The footer
  discloses that it sends movie/show identifiers, or titles and release years when
  identifiers are missing, to the public artwork
  service. Enabling it prefers Cinemeta posters/backdrops across shared shelves,
  grids, Plex search cards, Home heroes, and movie/show detail heroes, with Plex
  fallback. It never changes library ownership, watch state, playback, or Plex's
  selected artwork. The Mac directional settings scope includes the toggle.
  An unset preference defaults to enabled on both fresh installs and upgrades;
  a previously saved choice to disable it is preserved.
- Artwork also exposes Wide TV Hero Banners, on by default for the experiment.
  It requires Cinemeta Artwork and affects only wide Home heroes for series,
  trying a TVmaze gallery banner before the normal Cinemeta backdrop. Turning it
  off immediately clears Home's preloaded backdrops and restores normal selection.
  Movie heroes retain Cinemeta's background; unavailable series banners fall back.
  TVmaze is credited with a website link on iOS and a URL row on tvOS.
- Wide Movie Hero Banners is also on by default and appears when the app build
  includes a Fanart.tv project key. It needs no end-user credentials and affects
  only wide Home movie heroes; turning it off restores the normal Cinemeta
  background immediately. Fanart.tv attribution appears beside the TVmaze credit.
- iOS settings use `List`, `Section`, `Picker`, `Toggle`, `Link`, Safari sheet, and
  confirmation dialogs. On the macOS Designed-for-iPad runtime, the root list is one
  shared vertical directional group: Up/Down selects rows, Left/Right changes picker or
  toggle values, and Return/controller A opens an explicit choice sheet for a
  picker or activates the selected action. `DuskChoiceSheet` defaults to the
  current value and supports held navigation and B/Backspace/Escape. The root
  scope yields while its own sheets/dialogs are presented, and includes Privacy
  Policy and Help Improve Dusk. Mac Navigation Tabs and Library Order use
  position choices instead of requiring drag reordering. Keep the scope disabled
  while Settings is not the active root tab.
- tvOS settings use `ScrollView` plus `TVSettingsSection`, `TVSettingsMenuRow`,
  `TVSettingsToggleRow`, and action/link row components. The page leads with a
  `.title` "Settings" header (tvOS has no nav-bar title). Shared spacing lives in
  `TVSettingsMetrics` (`contentInset`, `cardVerticalPadding`, `sectionSpacing`) so
  the header, section labels, card content, and footers stay aligned. Keep tvOS
  rows focus-friendly and avoid iOS list-only affordances there. Each focusable row
  shows focus with `tvSettingsRowFocusHighlight(_:)` — a neutral background band
  driven by a per-row `@FocusState` (rows can't use the scale+glow effect because
  they sit inside a shared card). Any new tvOS settings row must carry that band, or
  it will be invisible when focused (`.duskSuppressTVOSButtonChrome()` strips the
  system focus effect, leaving no indicator on its own).
- When the signed-in account has multiple Plex Home members, both settings
  platforms show a Plex Home section with the current user, `Switch User`, and
  `Automatically Sign In`. The switch action reuses the startup picker as a
  sheet on iOS and a full-screen flow on tvOS. The toggle is device-local:
  turning it off removes the persisted active-session token but keeps the
  current in-memory session until the app ends.

## Platform Differences

- Prefer separate platform composition files for large differences:
  `HomeIOSView`/`HomeTVView`, `SettingsIOSView`/`SettingsTVView`.
- Prefer shared modifiers/helpers for small differences.
- tvOS often needs larger poster metrics, explicit focus sections, `scrollClipDisabled`,
  explicit page backgrounds, plain/custom poster focus, glass button styles for primary
  actions, and default focus restoration.
- For tvOS detail pages, use focus sections as vertical row boundaries when a row's first
  focusable item may be horizontally offset from the current control.
- iOS often needs navigation title display modes, searchable placement tuning, status bar
  behavior, refreshable lists, Safari sheets, and compact action stacks.
- tvOS should not rely on iOS-only `List` styling, context menu behavior, or touch drag
  gestures without a remote/focus alternative.
- When a view measures full-bleed hero artwork on tvOS, account for safe-area leading and
  trailing insets so backdrops span the visual screen.

## Design And Style Rules

- `STYLE.md` is authoritative. Use `Color.duskBackground`, `duskSurface`,
  `duskTextPrimary`, `duskTextSecondary`, and `duskAccent`.
- Root feature screens should paint `Color.duskBackground.ignoresSafeArea()`.
- Elevated rows/cards use `Color.duskSurface` and subtle 1pt strokes.
- Primary action buttons use neutral contrasting Liquid Glass (`Color.primary`-tinted
  prominent glass), not the coral accent. Reserve `Color.duskAccent` for progress,
  ratings, active states, and inline links. Do not introduce ad-hoc brand colors.
- Posters use 16pt corners. Sheets/cards use the larger rounded style already present in
  settings and library rows.
- Prefer system materials for overlays and hero controls where existing UI does.
- Use SF Symbols for iconography and keep labels concise.
- Keep content-first layouts: artwork leads, text supports, chrome recedes.
- Preserve progress indicators on posters and rows where watch state exists.
- Do not duplicate formatting logic in views. Add to `MediaTextFormatter` or an existing
  presentation helper.
- Do not make views call `PlexService` directly unless the file is already a small bridge
  around image URL construction. Feature data loading belongs in `@Observable` view models.

## Safe Change Checklist

- Read the relevant view, view model, shared primitive, and route code before editing.
- Confirm whether the change belongs in a platform shell, shared primitive, view model,
  route enum, or settings preference.
- Keep edits scoped; other agents may be working in nearby files.
- Reuse `AppNavigationRoute` and `.duskAppNavigationDestinations()` for navigation.
- Reuse shared poster/grid/carousel/state/formatting helpers before adding new UI.
- Keep Plex API calls in view models or `PlexService`, not view bodies.
- Preserve refresh-on-player-dismiss behavior on screens showing watch state.
- Preserve offline fallback paths and pending sync recording on downloaded media flows.
- Check tvOS focus and iOS compact layout when touching shared view code.
- If adding/removing/renaming source files under `Dusk/Sources`, run `xcodegen generate`.
- After code changes, run the compile-only `xcodebuild` command from `AGENTS.md`.
- Documentation-only changes do not require an Xcode build.

## Plex Matching

- Plex matches items to agent metadata; that match is where the title, summary,
  cast, artwork and the IDs used by subtitle search and Cinemeta come from.
  Dusk repairs it in two ways, both owner-only (`PlexService.canChangeMatches`):
  - **Automatic**, for items Plex never identified (`isUnmatched`). Movie, show
    and episode detail loads and playback start call
    `PlexService.autoMatchIfUnambiguous`, at most once per item per session. It
    searches with `MediaTitleCleaner` guesses (Plex's title, then the file name
    with release junk stripped) and applies a candidate only through
    `PlexMatchCandidate.unambiguousMatch`: the single candidate whose title
    (letters and digits) and year agree, with an exact-punctuation tie-break
    ("GOAT" over "G.O.A.T"). Anything still ambiguous is left alone. One refused
    PUT stops attempts for the session.
  - **Fix Match** (`Features/Detail/PlexFixMatchView`, iOS/iPadOS), from the
    secondary icon row of movie and show details. It seeds the search from the
    file name rather than Plex's title, since a wrong match means the current
    title is wrong, and shows each candidate's poster and summary.
- Every applied match bumps `PlexService.metadataRevision`; Home, library
  grids/recommendations and detail screens reload on it, so the new title,
  summary and artwork (Plex's and, through the new IMDb GUID, Cinemeta's) show
  without a manual refresh. Candidate posters load without Plex credentials.
- Until an item is matched, `CinemetaArtworkService` still finds Cinemeta
  artwork by exact title + year, trying Plex's title, then `MediaTitleCleaner`
  guesses from that title and the file name (only the cleaned title is sent).
