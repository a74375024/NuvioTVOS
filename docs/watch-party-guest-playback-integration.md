# Watch Party guest source → tvOS player: integration audit (CP-316)

Status: **Experimental guest binding prepared (CP-335), NOT compiled or tested**. 2026-10-20 UTC. Earlier audit and server-contract findings remain below.

## Verified current code paths

- `WatchPartySession.receive("stream")` validates a message claiming the current host member ID, exact `mediaKey`, URL syntax and headers; it retains `sharedStream` only in memory.
- `selectSharedStream(_ expected:)` returns an inert `WatchPartySharedStreamSelection`. `isCurrentSharedStreamSelection` guards generation, connection, stream revision and exact room media identity.
- `WatchPartyStream.playbackCandidate()` constructs `NuvioStream` with **request headers** and separately retains `responseHeaders` in metadata. Do not put response headers into request headers.
- Existing own-source flow: `NuvioTVApp.launchPartyPlayback` validates exact title/episode, obtains `watchPartyOwner.preparePlayback(media:)`, then invokes `presentBuiltInPlayer(... party:)`.
- `presentBuiltInPlayer` owns player surface, PiP invalidation and `playbackPartyID`. `PlayerViewModel.load` currently accepts request `httpHeaders` but has no corresponding public `responseHeaders` parameter. Directly routing a received source through it could lose response-header semantics.
- CP-335 wires an explicit `Use host's source` lobby action to catalog metadata resolution and the existing `preparePlayback` / `presentBuiltInPlayer` path. It requires the same accepted membership, source revision, room media, authenticated service context and navigation revision after the metadata await. It does not auto-play upon receipt. `Refresh host's shared source` still sends only the existing `state_request`.
- Upstream `WatchPartyConfiguration.isEnabled` was false at `08e4fa9`, but **true** at `4dd0f9b`; release notes for beta 3.4.5 still describe it as gated. Treat this as a code/release-note timing discrepancy, not a reason to change the flag in our branch.

## Integration and release checks

1. Verify host identity from the trusted realtime channel/auth contract, **not solely** from the `member_id` claimed inside a client-supplied JSON payload. A guest in the room may otherwise be able to forge the host's member ID if the realtime backend permits peer broadcasts. This is a **QA/security hypothesis**, not a reproduced exploit.
2. CP-335 explicitly rejects nonempty response headers before metadata loading; both player entry points receive request headers only. Validate this fail-closed behavior on Aether and MPV. No response headers are dropped or merged.
3. Resolve the room media to authoritative `NuvioMeta` and an exact `NuvioVideo` (for episodes), not title-text search; no auto-play if IDs do not match.
4. Confirm the source is HTTP(S) and provider-portable; local torrents, LAN sources, IP-bound Debrid URLs and expired tokens may not work. A successful URL parse does not guarantee remote playback.
5. Require explicit guest selection; before every async boundary and just before player presentation, recheck `WatchPartySession.isCurrentSharedStreamSelection`, membership, host, room ID and media key. Never retain source URL in analytics, logs or crash reports.
6. Attach the player via the existing `WatchPartyAppOwner.preparePlayback`/lease lifecycle. Do not reuse a detached player, bypass the PiP ownership checks or start a second room.
7. If playback fails or the source is revoked, return to the same room with `Choose my own source` available. Avoid automatic retries of private URLs.
8. Test both Aether and MPV, reconnects, revocation during resolve, change of episode, host leaving, profile change, and PiP return on a physical Apple TV.

## Backend room-lifetime source storage

Separate RFC: `docs/watch-party-room-source-lifecycle-rfc.md`. Current realtime `state_request` can ask an **online Android host** to resend its in-memory source, but it cannot satisfy the user's goal of recovering a source after the host app terminates. That requires an authenticated, revocable, server-owned room source record with TTL and explicit host consent. No backend repository with the authoritative room contract has been identified in this session.

## Current delivery status

**Experimental branch for maintainer review; NOT ready for release/merge without the checks above.** No Xcode build, XCTest, Apple TV/Fire TV QA or backend integration was run. No confirmed exploit/severity is assigned to the unverified host-identity concern.

## Return-to-player audit (CP-321)

Status: static review completed; return UI is not implemented.

- Normal Back in ContentView.dismissPlayer calls WatchPartyAppOwner.finishPlayback unless the exact owned coordinator is actively in PiP or restoring. finishPlayback invalidates the lease/runtime and clears the presentation. Keeping room membership does not retain the player.
- WatchPartyPlaybackRuntime.detachFullscreen invalidates the resource when keepingPictureInPicture is false. A stale lease cannot be restored merely by retaining its URL or room ID.
- The lobby's current Catch up with room action invokes catchUpWithWatchParty on a live mount; it does not navigate back to the fullscreen surface.
- The working system PiP restore path calls WatchPartyAppOwner.restorePlayback for the exact coordinator, rebuilds the root player surface from ActivePlaybackContext, and waits for fullscreenSurfaceDidRebind before completing AVKit restoration.
- Calling stopPictureInPicture directly is not a return-to-player implementation: didStop without the restoration handshake runs onDidStopPiPWithoutRestoring and invalidates the Watch Party player.
- Do not call onRestoreUI directly from the lobby or synthesize AVKit delegate callbacks. A future sidebar return action needs a supported restoration entry point that owns the generation, coordinator, pending completion and surface-rebind handshake.
- Before implementing that entry point, define whether normal Back should stop playback (current semantics) or retain it through a distinct explicit action. Do not silently keep audio/video running behind the sidebar or promise restoration after app termination.
- When the lease has already been released, keep Choose my source as the available action. When PiP is live, system expand remains the existing restore route until the new action is implemented and tested.
- Required integration checks: same coordinator and membership, movie/episode identity, PiP start failure, close versus expand, source replacement, profile/auth change, room end and stale onDisappear callbacks. Cover Aether and MPV separately; the current PiP manager requires the Aether backend.

## Server-contract discovery (CP-321)

WatchPartyAPI uses authenticated PostgREST RPCs watch_party_create/join/heartbeat/update and related functions. Searching the app repositories for realtime.messages policies and accessible NuvioMedia server/sync repositories did not identify the authoritative backend implementation. An empty search is not proof that no backend exists.

Before guest shared-source playback or room-lifetime persistence, obtain the server repository/migrations for these RPCs and the private watch-party channel authorization policies. The member_id claimed inside a peer message alone does not establish its authenticated sender. No server writes, Android writes, source forwarding, migrations or new playback button were added by this audit.

## CP-335 bounded guest playback implementation

- A guest explicitly selects a received HTTP(S) source from the lobby. No source probe, automatic retry, host resend cache or room-lifetime source storage is added.
- The local catalog must resolve the exact movie identity or one unambiguous season/episode, including season zero. Unknown titles, missing/duplicate episodes and unsupported metadata types are rejected; display titles never establish identity.
- Selection is checked before and after metadata resolution and again immediately before player ownership is acquired. Revocation, reconnect, host/media/membership/profile changes, cancellation or leaving and returning to the tab invalidate preparation.
- The existing Watch Party player ownership and PiP path is reused. The received source is marked on its PlayerViewModel before load so its URL/request headers are not saved to LastPlaybackStreamStore as a reusable own-source link; normal progress tracking remains. This is not a claim that the entire existing player/engine diagnostic pipeline has been audited for private URLs.
- Eight focused resolver tests were written, not executed. The reusable-link persistence guard and actual UI/player integration still need device validation.
- A transient broadcast still does not acknowledge guest receipt. An offline or late-joining guest may need the host to share again. A tvOS host does not automatically resend on state_request; existing one-send consent semantics remain.
- The public main broadcast adapter still serializes the SDK envelope. Supra's private-beta payload-unwrapping fix must be retained in the tested build; CP-335 does not duplicate or reopen closed PR #302.
- Authoritative backend channel authorization is still unverified: comparing a claimed member_id with hostMemberID is not sender authentication. Maintainer must validate the private-channel publishing policy before enabling/releasing this experimental path. No backend policy or server trust guarantee is asserted by this branch.
