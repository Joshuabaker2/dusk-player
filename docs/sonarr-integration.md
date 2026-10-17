# Sonarr Acquisition

Sonarr is an optional acquisition companion for **existing Sonarr-managed shows**.
Plex owns playable media, watch state, identity and offline downloads. Sonarr
records never receive synthetic Plex rating keys or enter the playback engine.
The UI is available in the iOS app, including iPad and its Designed-for-iPad Mac
runtime; tvOS keeps its current Plex/Seerr behavior.

## Ownership and connection

- `SonarrService/` owns URLSession, Keychain connections, exact series matching,
  shared foreground polling, search commands, monitoring and import reconciliation.
- `Models/SonarrModels` contains only consumed response fields and presentation
  unions. Optional Plex episode GUIDs allow safe external-ID joins; Plex show
  Locations supply the paths for scans.
- `SonarrSettingsViewModel` owns setup actions. `SonarrDetailViewModel` attaches
  show/season screens to the shared store, so views submit through view models.
- `SonarrAcquisitionViews` owns dimmed artwork, transfer overlays and missing
  episode rows/cards. It does not own a separate season screen.
- `SeasonDetailView` is the sole season layout for both Plex and Sonarr entry
  points. `SeasonDetailViewModel` uses an explicit Plex/managed-season source;
  lightweight display metadata is separate from real Plex details/identifiers.
  Both available and missing rows use `SeasonEpisodeRowLayout` and the same text,
  summary and divider primitives.

Each Plex profile/server context has at most one connection. The normalized
base URL and administrative instance API key live in Keychain. Disconnect removes
that context; Plex sign-out removes all saved connections. A context change
cancels requests, clears snapshots and pending command IDs, and restarts visible
subscriptions with the new credentials. Setup validates system status and series
access before replacing a connection.

Schemeless URLs mean HTTPS. HTTP requires an explicit scheme. Reject URL userinfo,
queries and fragments; preserve reverse-proxy paths. Send `X-Api-Key` in a header,
never in a URL or log. Redirects and authenticated artwork stay on the original
scheme/host/port. No Plex token is sent to Sonarr and no TLS validation is bypassed.

## Matching and presentations

A Plex TVDB GUID selects a unique managed series; unique IMDb is a fallback.
Conflicting or ambiguous IDs produce an explanation, never a title-based guess.
Episodes join by TVDB episode ID when present. A numbering fallback additionally
requires agreeing titles or an unambiguous matching air date for existing Plex
episodes. Conflicts, duplicate mappings or unverifiable ordering suppress
automatic missing-content enrichment. Alternative/DVD/anime ordering must be
aligned for automatic enrichment rather than guessed. Interactive replacement
searches validate only the chosen episode and can accept an explicit Sonarr
episode choice; they do not relax bulk matching. Plex browsing remains usable
when enrichment fails.

Seasons and episodes are merged by number; specials stay in season zero.
The episode detail browser also subscribes to the shared store: both its horizontal
shelves use merged season/episode presentations, not the raw Plex arrays. Existing
and missing season cards both select their episodes in place, keeping the standard
artwork, horizontal carousel and cast sections. After explicit mouse/controller
selection, focus moves to the selected season's first episode; existing scroll
readers reveal that shelf so selection is visible even when it was above the
viewport. Missing selections are tracked by season number rather than a fake
Plex key, and retained while imports arrive.

Show-grid/direct `.sonarrSeason(showKey:seasonNumber:)` links open the same
`SeasonDetailView` used for ordinary Plex seasons. Its view model can present a
managed season before Plex creates it, using show artwork/logo and Sonarr episode
metadata. Only a real season rating key enables Plex season actions. Once Plex
exposes the season, that same mounted view loads its real details and playback
controls without replacing the screen. Missing rows share standard artwork sizes,
text/summary layout and dividers; acquisition adds dimming and progress. Keep
presentation IDs stable for focus, scrolling and file picker activation when
external placeholders become real Plex episodes.

Missing-season artwork uses `SonarrSeasonArtwork`, shared by show and episode
browser cards. Missing-episode cards and season-page rows use
`SonarrEpisodeArtwork`. They request `.seasonPreview(number)` or
`.episodePreview(season:episode:)` against the real Plex show identity, reusing
Cinemeta's cached episode stills and image loader. Both obey the Cinemeta Artwork
opt-out. Only thumbnail URLs are retained from video metadata; aggregate episode
URL entries are trimmed to 12,000 across cached series (one larger series can
occupy the cache alone). Sonarr fallback prefers an episode
screenshot, then season art, then a series landscape image over its logo/poster.
No placeholder Plex season, player seeking, server screenshot generation, or new
credential-bearing image path is introduced.
Presentation IDs remain stable through import. Existing Plex episodes keep their
normal playback, watched and offline controls. Sonarr-matched shows suppress
Seerr missing-season cards, even if a retained Sonarr snapshot temporarily fails
to refresh; Seerr remains available for discovery and unmatched series.
Offline/cached detail screens are not enriched.

## Browsing status presentation

Matching/connection/import diagnostics never render a raw warning and retry block
between the hero and shelves. `SonarrDetailViewModel.downloadIssue` translates
stored diagnostics into a short user-facing explanation. A quiet info button
beside the Episodes/Seasons heading opens Download Information only on request,
with Refresh and collapsed Technical details. Mouse, touch and gamepad use the
same app-owned navigation panel, and only an actual issue exposes the button.

The matching explanation describes the practical effect: missing episodes may
not be listed; existing files still play and interactive replacement remains
available. Keep raw server/mapping messages for explicitly opened technical
details and action-specific errors, not passive browsing. Once imports appear
in Plex, clear any stale scan diagnostic so the status control disappears.

## Acquisition and activity

Clicking an aired missing episode immediately reserves it as Searching and
requests an automatic Sonarr `EpisodeSearch`. Clicking a missing season opens
its episode list. Download season searches its missing aired IDs, monitors that
season and its missing future episodes. Individual acquisition monitors only
selected episodes; Sonarr's series-level monitoring must also be enabled for
ongoing acquisition. Other season flags, future-season policy, paths and quality
profiles are preserved. Sonarr owns release selection and the download clients.

A fresh read precedes writes. Skip Plex-present, Sonarr-imported, queued and
actively searched episodes. Mutations serialize per show while individual taps
reserve their own episode IDs. Season Pass applies targeted series/season flags;
`episode/monitor` sets only the selected missing episode IDs. No client-side
background job queue is persisted.

Read queue details and command status separately. Reconstruct active episode
searches from command bodies after reopening. Completed commands allow another
explicit search when no release was grabbed; they do not mean a download finished.
Unknown command responses remain blocked from automatic retry. An explicit
Search again context action is available after checking Sonarr status. Network
ambiguity never triggers an automatic command repeat.

Overlays distinguish Searching, Queued, Downloading, Paused, Importing, Waiting
for Plex, Needs attention and search failures. Percentage uses size/sizeleft
only when supplied; otherwise show indeterminate progress. Season transfer
percentages count each download ID once (including packs), with a separate
Plex-available episode count. Future episodes show their air date.

A button's submission task is independent of the detail screen's observation
lease: navigating elsewhere does not cancel the handoff. Once Sonarr accepts the
command/release, server-side searching, downloading and importing continue even
if Dusk closes. Dusk backgrounding cancels its own status requests, not Sonarr's
work. On return, visible screens reconcile authoritative commands/queue/files.

One task polls visible show leases every 5 seconds during active searches,
transfers or the first 2 minutes waiting for Plex; idle/longer import waits use
30 seconds. Failures back off to 15/30/60 seconds. Backgrounding cancels polling
and in-flight URLSession work; foregrounding reconciles current server state.

## Replacement files and gamepad Y

`MediaVersionPickerView` remains the shared gamepad-Y / Select File panel.
For online TV episodes with a Sonarr connection it also offers **Download a
different file**. Episode right-click/long-press menus expose Select File and
Download a different file through `MediaFileContextMenu`, using the same panels
and eligibility rules as Y. The parent screen owns both presentation bindings so
dismissing the native menu cannot discard the requested panel. `SonarrReleasePickerViewModel` resolves the real Plex episode
through the existing exact Sonarr match, then reads `/api/v3/release?episodeId=…`.
Replacement lookup is scoped to the selected episode, independent of unmatched
specials or other seasons. Use an exact TVDB episode ID first, even if display
numbering differs. Otherwise require unique season/episode numbering plus a
non-generic agreeing title or a unique matching air date. If unresolved, present
an explicit episode chooser within the exact matched Sonarr series; do not show
an empty release list or silently choose an uncertain numbered episode. The
choice is scoped to this search/context and never persisted as a show-wide map.
Recheck the series, selected episode and existing file ID before grabbing;
automatic target matching is repeated unless the user chose it explicitly.
Replacement progress and focused scans remain available even when the bulk
show-order map is incomplete.

Results retain Sonarr's rank order and show quality, size, indexer, score,
reported languages, seeders, season-pack scope and rejection reasons. Rejected
releases remain in the list (unmapped/unrequestable rows are disabled); only the
explicit English toggle filters displayed releases. The English
filter uses Sonarr's reported language only. Dub/Dual/Multi title labels are
explicitly unverified hints. Language parsing does not guarantee embedded audio.

Manual selection posts only the cached release GUID, indexer ID and matched
episode ID to `/api/v3/release`. Require an exact mapped series/episode match and
Sonarr's downloadAllowed flag; do not override parsing, delete the existing file,
blocklist releases, modify profiles or remove queued downloads. Show automatic
rejection reasons even when a manually mapped release can be selected. Disable
the known current scene-name release. Expired result caches require a fresh
search; uncertain POST responses never trigger automatic resubmission. Existing
searches, submissions and queue entries prevent duplicate replacement grabs.
Interactive indexer lookup allows 90 seconds; normal request inactivity remains
15 seconds with a 120-second resource ceiling.

Replacement jobs are transient shared activity. Remember the Sonarr file ID and
Plex part/file/size/audio signature at selection. A changed Sonarr file ID triggers
a focused Plex show scan even when the episode already has a Plex rating key.
Refresh until Plex's available-file signature changes, then publish
metadataRevision so detail/file menus and language indicators reload. The panel
and episode shelf show replacement progress; Sonarr owns replacement/import
policy and may require attention for rejected imports. A relaunch loses transient
replacement baselines but the ordinary server queue remains authoritative.

## Plex import reconciliation

Sonarr `hasFile` indicates import, not playability. If Plex lacks the episode,
request `GET /library/sections/{section}/refresh?path={Plex show Location}` through
`PlexService+Acquisition`. Use Plex's paths exclusively: Docker/remote mounts can
differ from Sonarr's paths. Scan permission requires an owned Plex server and an
unrestricted active identity; server denial is reported without blocking playback.

Coalesce scans per show (at least 30 seconds apart) and remember scanned file IDs
in memory. A denied/unsupported scan is not repeatedly submitted. Refresh
availability explicitly retries a focused scan. Re-fetch seasons and episodes
until Plex exposes the import; only then publish metadataRevision and enable
normal playback. Missing Location data and delayed indexing retain Waiting for
Plex; explanations are available through the shelf-header Download Information
control. No full-library scan or metadata refresh is substituted.

## Verification

Regenerate with `xcodegen generate` when sources change. Compile iOS and tvOS with
the arm64 overrides in `AGENTS.md`; do not run tests or launch app/simulator.
Runtime acceptance, when performed by a human, should cover:

- With a show-order mismatch, browsing must retain normal spacing and playback;
  only the shelf-header info button should appear. Verify friendly explanation,
  explicit technical details, refresh, one-step Back/Done and gamepad navigation;
  resolved scans should remove the status indicator.
- URL subpaths, explicit local HTTP, invalid/revoked keys, cross-origin redirects,
  disconnect, sign-out and Plex profile/server switching.
- Enter Marple (or another partial series) through an episode detail route as well
  as show/season routes; missing seasons must appear in its season preview shelf,
  clicking any season must reveal its episodes in the same standard carousel;
  clicking a missing aired episode submits acquisition. Direct missing-season
  links must use the standard season screen and acquire/play rows must share its
  normal artwork and spacing. Verify mouse click and gamepad A/Enter, distinct
  season and per-episode stills (including missing episodes in both horizontal
  cards and season-page rows), slow/missing artwork and Cinemeta Artwork turned off.
- Partial and absent seasons, single-click requests, rapid different/duplicate
  taps, future episodes, specials and incompatible episode ordering.
- Compare right-click/long-press and gamepad Y on episode cards, season rows and
  Play controls: Select File and Download a different file must reach the same
  panels; offline/disconnected contexts must not offer Sonarr replacements.
- A mismatched special/unrelated season must not block a verified episode's
  replacement search. Verify exact IDs with differing display numbering, a
  translated/unmatched title requiring explicit episode selection, changed
  file/series/context before submission, and rejected releases remaining visible.
- Y on an existing episode → Download a different file: English filter, ranked
  results, unknown/dual hints, current file, rejected/unmapped releases, expired
  results, duplicate selection and uncertain submissions. Confirm old files are
  retained until Sonarr imports and the same Plex episode refreshes afterward.
- Existing files/queue entries, no releases, stalled commands, reopening during
  search, paused transfers, pack percentages and blocked imports.
- Different Sonarr/Plex mounts, denied/missing-path scans, delayed Plex indexing,
  foreground restoration, Seerr precedence and unaffected offline playback.

Adding shows, external discovery, Radarr, central activity pages and tvOS setup
are deferred. Keep future acquisition integrations separate from Plex; there is
no generic media-provider protocol.
