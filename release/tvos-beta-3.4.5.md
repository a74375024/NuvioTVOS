## tvOS Beta 3.4.5

> **Install:** [NuvioTV-3.4.5-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.4.5/NuvioTV-3.4.5-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

> 🎉 **Thank you for 200+ GitHub Stars!** A huge thank you to everyone in the community for supporting NuvioTVOS and helping reach 200+ stars on GitHub! Your feedback, issue reports, and testing make this possible.

### Playback Engine, Subtitles & Telemetry Improvements

- **Stream Picker Performance:** Pre-computed stream candidate sort keys (`StreamPickerSortKey`) to eliminate sort churn and UI stutter when browsing complex stream sources.
- **Forced Subtitles & Independent Matching:** Respected forced subtitles during automatic track matching, and unlocked "Match Subtitle Language" outside of "Auto Select Stream" in Settings.
- **Subtitle Preview Parity:** Normalized subtitle font styling and bounded subtitle preview layout, opacity, and tracking clamps to match live player renderers.
- **Preserved Source & Row Identity:** Maintained original stream source and row identity across resolved playback URLs, preventing stream state resets and preserving watch progress tracking.
- **MPV Engine Resilience:** Aborted startup cleanly on initialization failure, cleared omitted HTTP headers across loads, and retried display criteria until valid frame rates are detected.
- **Playback HUD & Issue Reporting:** Bounded opt-in playback issue reports and honored the hidden swarm stats preference in the playback HUD.

### Trailers, Artwork & Visual Polish

- **Smooth Trailer Activation:** Bounded trailer preview delays and ensured trailer readiness activates smoothly during autoplay transitions.
- **Artwork Cache Preservation:** Preserved artwork caches when entering and leaving playback sessions, and bypassed stale local HTTP caches when refreshing poster artwork.
- **Top Shelf Integrity:** Ensured Top Shelf snapshots remain strictly ordered across detached writes and pruned obsolete artwork from previous feeds.
- **AMOLED Surface Styling:** Honored AMOLED Surfaces preference across shared card and row modifiers for pure blacks on OLED displays.

### Cloud, Library & Multi-Profile Hardening

- **Serialized Watchlist Mutations:** Serialized remote watchlist toggles from the Details screen and ignored stale mutation rollbacks to eliminate race conditions.
- **Continue Watching & Simkl Deduplication:** Deduplicated Continue Watching aliases without resurrecting previously removed cards, and deduplicated Simkl Up Next seeds using canonical content aliases.
- **Profile-Scoped Operations:** Add-on edit uploads, collection edits, and Continue Watching snapshots are strictly scoped to their originating profile.
- **Localized TMDB Cache Protection:** Protected TMDB request configurations across asynchronous boundaries and rejected pre-clear localized cache writes.
- **Jellyfin Editor Cancellation:** Cancelled pending Jellyfin server saves cleanly when the editor is dismissed.

### Feature Updates

- **Watch Party Gated:** The experimental Watch Party feature has been temporarily disabled pending server coordination and room lobby finalization.

### Tests & Stability

- 1,205 automated unit and regression tests passing with 0 failures across playback backends, stream caching, subtitle rendering, sync services, and layout settings.

### Known issues

- Picture in Picture requires a supported Apple TV 4K / tvOS 15+ device.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
