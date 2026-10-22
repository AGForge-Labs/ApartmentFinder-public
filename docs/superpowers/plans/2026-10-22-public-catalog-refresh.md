# Public Catalog Refresh Implementation Plan

**Goal:** Deliver versioned, offline-safe public pin-data refresh using the existing repository and private TestFlight channel.

**Architecture:** A fixed public JSON feed plus verified immutable local public generations. Existing public supplement merge rules project the active snapshot over private packs; personal records stay independent. The share extension reads the same atomically selected public address index.

**Tech stack:** Existing Swift/Foundation/CryptoKit/SwiftUI and Python standard library; no new service or dependency.

**Spec:** `docs/superpowers/specs/2026-10-22-public-catalog-refresh-design.md`

## Global constraints

- Preserve 26.1 rollback, all personal/verified pins, private generations, tester scope and existing credentials.
- Only public JSON data under the fixed `catalog-data` repository branch; three bounded content files, no remote code.
- Preserve source/estimate/verification and full-street/unit/floor distinctions. Keep private import limits unchanged.
- One final applicable app pass after combined supported changes, then compile/private release on success; no duplicate unchanged full suites.
- No production research media, private fixtures, recipient fields, manifests, access codes or private notes in feed/repository.

## Review focus

1. Interrupted writes/requests must not activate a partial generation.
2. Stale/replayed/rolled-back revisions must not silently override the owner's selected known-good copy.
3. A valid hash does not excuse bad schema, false precision, duplicate IDs or private fields in publishing input.
4. Refresh while personal edits/private imports complete must project the newest personal/private state, preserving their bytes.
5. Offline refresh failure and address-index reads must keep pin editing, parsing and current navigation usable.

## Task 1 — Public payload, bounded transport and atomic store (core owner)

- Create `Sources/ApartmentCore/PublicCatalogUpdate.swift` (split focused files if needed) and `Tests/ApartmentCoreTests/PublicCatalogUpdateTests.swift`.
- Public interfaces: `PublicCatalogUpdateManifest.read(Data)`, manifest `revision/sequence/packVersion/files`; `PublicCatalogUpdatePayload(manifestData: Data, files: [String: Data])` with validated `pack`; `PublicCatalogUpdateSelection` containing `pack/manifest/recoveredPrevious`; `PublicCatalogUpdateStore(directory:)` with synchronous `load/install/rollback/knownAddresses`; `PublicCatalogUpdateClient(fetch:)` with `latestManifest() async throws -> Data` and `payload(manifestData:) async throws -> PublicCatalogUpdatePayload`. Fetch type is `@Sendable (URL, Int) async throws -> Data`; production transport is bounded and fixed-host with redirects rejected.
- First write tests for invalid hash/length/schema/path, no-op same revision, lower-sequence rejection, interrupted activation, previous fallback, manual rollback rejection of the bad revision, duplicate identities and matching index. Preserve all raw record IDs and qualifications.
- Implement the smallest public-only store using the existing private-store pattern, without routing public payloads through private 2 MB limits.
- Report exact new test IDs to the integration owner; do not dispatch native/Core CI separately or edit selection inventories.

## Task 2 — Publisher and data-only branch layout (publisher owner)

- Create `scripts/public-catalog-feed.py` and `Tests/public_synthetic/test_public_catalog_feed.py`.
- `prepare --directory data --output <staging> --revision <segment> --sequence <positive-int>` runs existing public admission, serializes lossless compact JSON, writes immutable revision files and manifest, and verifies bytes/digests/packVersion. Reject unsafe/reused revision, non-increasing sequence when previous manifest is supplied, private-backup input, unknown payload files and weakened uncertainty flags.
- Write and run portable failing tests first, implement, then run affected portable cases. Add a concise operations guide. Do not mutate remote refs or publish independently; integration owner verifies/publishes through the existing authenticated route.

## Task 3 — AppStore, shared index and preservation (integration owner)

- Modify `App/AppStore.swift`, the shared container bridge and share extension's known-address reader. Load verified public cache before bundle fallback; leave private loading unchanged.
- AppStore UI contract: published `catalogRefreshPending: Bool`, `publicCatalogRevisionLabel: String`, `publicCatalogUpdateStatus: String`, `canRollbackPublicCatalog: Bool`, `publicCatalogDataRevision: UInt64`; async `refreshPublicCatalog(manual: Bool = true)`, `rollbackPublicCatalog()`, `refreshPublicCatalogIfDue()`.
- Keep downloads detached from the main actor; re-evaluate current private/personal state before publishing the new public projection. Do not use private import busy state to block offline editing during network waits. Add a separate public revision notification, not an unconditional navigation reset.
- Add native tests for offline cached reopen, invalid update leaves bytes/generation/personal state unchanged, successful update preserves confirmed door precedence, rollback and shared address lookup. Transport is injected; no live server in acceptance tests.

## Task 4 — Manual control and foreground checks (UI owner)

- Add `App/PublicCatalogUpdatesView.swift`, navigation entry points in existing Finder/Apartments toolbars and `UITests/PublicCatalogUpdatesUITests.swift`.
- Consume the AppStore contract above; expose `catalogUpdates.open`, `catalogUpdates.refresh`, `catalogUpdates.status`, `catalogUpdates.rollback` identifiers. Show current data/status and progress without covering the map.
- Root foreground task invokes throttled checks; manual refresh is immediate. Disable automatic live-network checks for existing UI fixtures and use controlled offline fixture transport in the new case. Preserve personal navigation unless an actively selected public target actually changes.
- New UI case proves offline failure keeps the installed catalog and in-app add/edit pin access usable. Report new test IDs; no independent full-suite dispatch.

## Task 5 — Final combined data and release

- Reconcile source-backed research additions and source/address gaps on this branch. Keep 9650 Ensworth as a separate missing address/phase candidate until its current relationship/units/geometry are supported. No blind merge into 9655.
- Independently review integration and privacy/identity/persistence behavior. Update exact test inventories while retaining every old identity/assertion.
- Prepare initial public feed from the final data snapshot, publish its JSON-only branch and verify exact remote files/digests through unauthenticated reads.
- Publish the app candidate/draft PR, run affected credential-free checks and the one final native/UI pass through the established release path, then sign/upload and verify Apple VALID/IN_BETA_TESTING and unchanged private audience. Preserve 26.1. Record actual pass/fail/not-run states and remaining coverage gaps.
