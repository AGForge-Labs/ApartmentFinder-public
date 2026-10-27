# Offline public compatibility fixtures

This draft adds a local Python fixture command and synthetic tests. It is an offline portion of Task 1 in the provisional complete-set capacity plan. It does not implement a set reader, prepare a set manifest, change the existing feeds, or enable any app behavior. The complete-set design remains unselected; the offline fixture format is provisional.

The command copies only the three exact public payloads plus an existing schema-1 baseline manifest, preserving raw bytes, JSON whole objects, original array order, source IDs, URLs, notes and qualifications. The separate public bundle has its real pack version and three file descriptors. It has no fabricated feed manifest, revision or sequence. An explicit minimum root sequence is supplied by the caller from reviewed history; the command only checks that it covers the pinned baseline sequence. It does not discover public history.

The tool uses a content-pinned, separate admission profile in `Tests/fixtures/public-catalog-admission-214c`. All seven files are copied unchanged from the later reviewed release profile. The existing `scripts/public-catalog.py`, old readers, three schema-1 payload caps and 512-byte publisher reserve are unchanged. This profile is test tooling; project resource lists are untouched.

Run from a checkout with Python 3.9 or later:

```text
python -B scripts/public-catalog-compatibility-fixtures.py prepare \
  --baseline REVIEWED_SCHEMA1_REVISION_DIRECTORY \
  --baseline-manifest-sha256 REVIEWED_MANIFEST_SHA256 \
  --bundle PUBLIC_BUNDLE_THREE_FILE_DIRECTORY \
  --bundle-descriptors REVIEWED_BUNDLE_DESCRIPTOR_FILE \
  --bundle-descriptors-sha256 REVIEWED_DESCRIPTOR_SHA256 \
  --admission-profile Tests/fixtures/public-catalog-admission-214c \
  --minimum-root-sequence REVIEWED_HISTORY_FLOOR \
  --output NEW_OFFLINE_FIXTURE_DIRECTORY
python -B scripts/public-catalog-compatibility-fixtures.py verify \
  --directory NEW_OFFLINE_FIXTURE_DIRECTORY \
  --admission-profile Tests/fixtures/public-catalog-admission-214c \
  --fixture-sha256 REVIEWED_FIXTURE_SHA256
```

These are argument examples, not shell commands to paste with unresolved placeholders. The baseline directory must contain exactly `manifest.json` and the three public payload names; the bundle directory must contain exactly the three payloads. Copy reviewed public files into dedicated input directories first. Never point this command at a personal backup, device export, delivery directory, or app store. Input/output overlap, links/reparse points, unknown files and existing outputs are rejected. No credentials, network client or publishing action exists.

The reviewed bundle descriptor input has exactly `fixtureFormat`, `packVersion`, and `files`. `fixtureFormat` is `ApartmentFinder-offline-public-compatibility-v0`; each of the three file descriptors has exactly `bytes` and `sha256`. Supply its independently reviewed raw SHA256. The minimum-root floor is separate from the bundle version.

The output is a private fixture directory with raw `baseline/` and `bundle/` copies, `bootstrap-anchor.json`, `conservation-registry.json`, and `compatibility-fixture.json`. The last file binds all nine other files and the original input pins. Retain its raw SHA256 from preparation and review it independently before verification. A coupled rehash of mutable fixture files cannot replace this trusted external identity. Verification decodes the same bounded bytes it hashed, rather than rereading mutable paths. It proves a captured snapshot; it is not a filesystem lock against later changes.

The finite conservation registry records counts, literal semantic twin memberships, equal-URL source identities, orphan sources, the Riley pair and the Spanish Wells exception. Full original values and order remain in the hash-bound baseline raw resources; the registry does not duplicate every record ID. The identity grouping is an explicitly limited ASCII source port of saved `LocalSearch` rules. It rejects non-ASCII identity inputs and claims no Swift normalization parity, whole-set admission, novel duplicate exception, or cross-runtime canonical JSON hash. No source object is merged by URL.

The private actual fixture uses delivered `.23/91`, including Solitude, and the separate saved `.13` bundle. Its exact source bytes and finite 102/204 twin memberships, 47 URL alias groups, 12 orphans, Riley 302/154 and Spanish Wells four source roles are retained. The fixture contains 219 communities, 1,479 sources, 38,963 location features and 17 paths. These are retained records, not new door or locker coordinates. Large raw files remain private evidence and are not new app resources.

Tests:

```text
python -B -m unittest discover -s Tests/public_synthetic -p test_public_catalog_compatibility_fixtures.py -v
```

The tests use invented public fixtures, literal expected memberships, raw byte equality, a validly rehashed private-field rejection, source closure, tamper/race controls and the exact unchanged reserve boundary. The tool retains bounded raw inputs and decoded Python objects in memory; it is not a proof of app memory use. It does not implement the proposed pre-Foundation token scanner.

Swift bootstrap parsing and fixtures, the full conservation reader, Main/Share resource integration and fallback inventories, actual set grammar, transport/store/policy migration and minimum-device budgets remain future work. No Swift/native validation, binary distribution, TestFlight update or physical door accuracy is established by this change.

Windows preparation and verification accept ordinary absolute local-drive paths and ordinary relative paths. Device, extended and UNC namespaces, drive-relative paths and root-relative paths are rejected before file inspection. The command never strips a device prefix or rewrites it into a trusted namespace; an unsupported namespace returned by canonicalization also fails closed. This narrows this offline command only and changes no app reader or live contract.

`Tests/fixtures/.gitattributes` disables Git text conversion only for `public-catalog-admission-214c/*`. The seven profile files retain their original byte identities, including the two helpers' CRLF endings. The attributes file is outside the exact-seven profile directory. No original repository attribute or general app-source newline policy changes. The Git regression stages these real fixture bytes with automatic line-ending conversion enabled, reads the actual index blobs, and checks an actual Git checkout against independently pinned hashes. Physical overlay tests alone do not establish committed-byte compatibility.

The profile-only whitespace attributes retain the default blank-at-eol, blank-at-eof and space-before-tab checks and add cr-at-eol for its original CRLF bytes. General whitespace checks stay enabled. Final fixture evidence distinguishes physical source, actual Git index blobs and actual Git checkout bytes; the earlier canonical-old/physical-new export alone is not staged or committed candidate proof.
