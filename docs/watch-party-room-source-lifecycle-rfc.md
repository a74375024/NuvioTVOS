# Watch Party — room-lifetime shared source (design proposal, not implemented)

Status: **RFC / backend-dependent / experimental**. Prepared 2026-10-19.
This document is not evidence that the existing backend stores or protects a shared source.

## Goal

A host explicitly approves sharing one playback source. While the room remains active and the host has not revoked that approval, a late-joining or reconnecting authenticated member can retrieve the same source without requiring the host device to remain online. Ending the room, stopping sharing, changing the room media, or expiry must invalidate the server-side record.

**Do not** infer consent from merely creating or inviting someone to a room. Creating a room and sharing a URL are separate user actions.

## Current wire behavior (verified statically)

- Android `PartyRepository.kt` resends its in-memory source on an existing `state_request` when `party.isHost && party.sharing`. It also resends on reconnect. If the Android app process stops, this is not durable storage.
- tvOS `WatchPartySession.connect` already emits `state_request`; the WIP branch additionally supports a throttled, guest-only manual refresh. Neither stores the source on the server.
- Existing server `WatchPartySnapshot` models on Android and tvOS have no shared-source field.
- A realtime `stream` event is transient. It is not a guarantee of delivery to a guest that was offline.

## Required backend API / authorization

Implement only after identifying the authoritative Watch Party server repository and its auth/storage contracts.

1. **Host upsert**: authenticated host-only mutation to set a source for a specific `room_id`, `media_key`, and consent/revision. Validate current membership, room state, media identity, payload size, allowed transport, and source shape. Do not accept guest upserts.
2. **Guest read**: authenticated current-room member may retrieve the active shared source by `room_id`. The server verifies membership using the same auth/device/profile context as the room API; possession of a six-character invitation code is **not** sufficient. Never expose a source in a public room preview.
3. **Host revoke**: authenticated host-only mutation invalidates the source and increments the revision. This must happen when sharing is disabled, room media/host identity changes, or room ends. A guest removed from the room loses retrieval access immediately.
4. **Cleanup**: server-side deletion on confirmed room end, expiration and administrative cleanup; a bounded TTL refreshed only while the room remains valid protects against orphaned records and process crashes. Never rely on Apple TV/Android application termination callbacks for deletion.
5. **Concurrency**: use a monotonically increasing revision or compare-and-set tied to room/media. Stale writes or delayed events cannot restore a revoked source. Responses must include the revision, room ID and media key, and a clear unavailable/expired outcome.
6. **Storage**: encrypt at rest with server-managed keys; minimize retention; do not log URL, headers, query tokens or decrypted payload; exclude from telemetry, crash reports and normal snapshots. Use transport TLS and authenticate both sides.
7. **Delivery**: send a **non-sensitive revision/availability event** over realtime, then fetch the source through the authenticated API. Do not broadcast the private URL to all channel listeners as a persistent state snapshot.
8. **Playback**: guest must explicitly select the source; validate exact movie/episode, active membership, revision and session generation before and after any async step. Keep HTTP request and response headers separate; reject unsupported origins and URLs.
9. **Revocation limits**: deleting the server record prevents future fetches, but cannot revoke a URL already delivered or a provider token that remains valid. Tell users this in the consent dialog.
10. **Provider restrictions**: provider IP/device/concurrency rules may prevent the guest from using a URL; never claim that persistence makes Debrid links universally portable.

## Suggested lifecycle

```
Host explicitly consents -> authenticated host upsert -> room source revision R1
Guest joins/reconnects -> membership check -> authenticated source fetch R1
Host switches movie -> revoke R1 -> require new approval -> optionally upsert R2
Host presses Stop Sharing -> revoke -> availability event only
Room ends / expires -> revoke and delete server record
Host app closes but room remains valid -> source remains available until revoked/expired
```

## Compatibility rollout

- Backend first behind a capability flag (e.g. `room_source_storage_v1`), with tests for host-only authorization, late join, reconnect, room end, host leave, media change, expiry, stale revision, member removal, and absence of secrets in logs.
- Android and tvOS add capability negotiation and opt-in use of the authenticated fetch/upsert. Legacy realtime `stream` and `state_request` behavior stays as a fallback until all supported clients migrate.
- Do not turn on server persistence solely from a tvOS PR. The server implementation and security review are mandatory.
- Confirm product policy with Supra before deciding whether a host leaving the room ends it or transfers ownership; source ownership must never silently transfer.

## Acceptance tests (not yet run)

1. Host shares, guest joins later: source is available from server only to authorized member.
2. Host app terminates while server room stays active: guest can still fetch until expiry/revoke.
3. Host ends room or disables sharing: future fetch returns unavailable, stale event cannot restore source.
4. Guest is removed / changes profile: future fetch denied, local cached source cleared.
5. Host changes episode: old source unavailable; no playback until exact-media validation.
6. Network race during revoke/upsert: older revision cannot overwrite revoke.
7. Diagnostics, analytics, database logs and UI never expose token-bearing URLs or headers.

Owner/backend repository: **not identified/connected in this session**. Implementation pending.
