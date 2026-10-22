# Public catalog feed operations

The feed uses the existing public `AGForge-Labs/ApartmentFinder-public` repository's `catalog-data` branch. The app reads `https://raw.githubusercontent.com/AGForge-Labs/ApartmentFinder-public/catalog-data/latest.json` without credentials. The publisher prepares local files only; it does not contact GitHub, build iOS, sign, upload or change tester access.

Use only an explicitly reviewed public bundle directory containing exactly these five files: `public-catalog.json`, `public-locations.geojson`, `public-paths.geojson`, `known-addresses.json` and `public-catalog-review.json`. Existing public admission checks must pass, including review digests, source joins, precision qualifications and estimate flags. A backup, device store, delivery manifest or personal export is never a publishing input. Field admission does not replace human source/privacy review.

Prepare a fresh staging directory whose parent exists:

```powershell
python -X utf8 -B scripts/public-catalog-feed.py prepare --directory data --output build/catalog-feed-staging --revision 2026-10-22.1 --sequence 1
```

For a subsequent revision, use the authoritative current feed manifest as an additional monotonic guard:

```powershell
python -X utf8 -B scripts/public-catalog-feed.py prepare --directory data --output build/catalog-feed-staging --revision 2026-10-22.2 --sequence 2 --previous-manifest build/current-public-latest.json
```

Use positive Int64 sequences that exceed every prior revision. Revision names are single ASCII segments matching `[A-Za-z0-9][A-Za-z0-9._-]{0,79}`, excluding Windows device names and trailing dots. Revisions cannot be reused, including case-only aliases. Supply the current manifest when preparing a fresh directory; a local empty directory cannot independently know remote history. Before publication, check the authoritative branch for any older use of the proposed revision too. Existing staging history is verified and never overwritten.

Successful preparation creates only:

```text
latest.json
revisions/<revision>/manifest.json
revisions/<revision>/public-catalog.json
revisions/<revision>/public-locations.geojson
revisions/<revision>/public-paths.geojson
```

The two manifests are byte-identical. Schema 1 has exactly `schemaVersion`, `revision`, `sequence`, `packVersion` and `files`. The three descriptors contain only `bytes` and lowercase `sha256`, calculated from the compact UTF8 wire bytes, including their final newline. Catalog/location/path budgets remain 3,000,000/64,000,000/16,000,000 bytes and the manifest is capped at 16,384 bytes. Compact serialization preserves JSON values, array order, IDs, full streets, floor evidence, source types and uncertainty; the derived known-address index and review file are admission inputs, not feed payloads. Private import limits are unchanged.

Publish through the existing authorized repository route only after source/privacy review and a successful publisher exit. Commit the new immutable revision directory and `latest.json` together in one Git commit. Retain older revision directories. The branch contains JSON only: no `.github`, workflows, scripts, credentials, private data or research artwork. A data-only revision needs no iOS build or TestFlight upload.

`latest.json` is locally replaced only after the stored revision verifies. A failed or interrupted command may leave an unselected complete or partial revision; do not publish that staging tree or blindly retry with the same revision. Inspect the result first, retain immutable completed revisions, and use a fresh reviewed staging directory when repair is needed. The command rejects incomplete/corrupt existing history rather than repairing or deleting it.

On sandboxed Windows runs, point `TMPDIR`, `TEMP` and `TMP` at an allowed workspace-local temporary directory before running the publisher/tests. The only focused test module is `Tests.public_synthetic.test_public_catalog_feed`; final combined app acceptance remains separate.
