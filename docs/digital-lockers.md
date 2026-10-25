# Digital package locker evidence

`Community.digitalLocker` is optional. Missing legacy data displays `Digital lockers · unknown`.

```json
{
  "digitalLocker": {
    "status": "present",
    "brand": "Luxer One",
    "placementDescription": "Inside the leasing lobby",
    "sourceIDs": ["property-electronic-locker-evidence"],
    "checkedAt": "2026-10-24",
    "point": {
      "longitude": -115.1,
      "latitude": 36.1,
      "locationSourceIDs": ["property-locker-map"],
      "precision": "sourceMapped"
    }
  }
}
```

The example is fictional. Omit `point` when the source proves existence without a supported location. `precision` is `sourceMapped` or `approximate`; it does not establish a physical door. The point has its own nonempty source references and must be inside the bounded research envelope. `placementDescription` and `brand` are optional. An explicitly evidenced electronic system may have an unreadable or unpublished brand; omit it rather than inventing a manufacturer. USPS, shared keyed parcel boxes, ordinary mailboxes and generic package rooms are excluded. Positive claims require electronic-system evidence; negative claims require explicit property-specific negative evidence. Website omission or ambiguous package wording is unknown. `absent` and `unknown` never have a point. All evidence source IDs resolve through the catalog source registry. `checkedAt` is an ISO calendar date. The optional field uses the existing catalog schema version 1; the transport manifest envelope also stays version 1.

The upgraded app refreshes `https://raw.githubusercontent.com/AGForge-Labs/ApartmentFinder-public/catalog-data/latest-v2.json`. Payloads remain under immutable `revisions/<revision>/` paths. Older readers reject the new community field and expanded ZIP scope. Keep `latest.json` compatible with the released app. Add compatible directory-only updates there; send optional locker fields and expanded ZIP scope only through `latest-v2.json`. Preserve every prior immutable revision byte. Prepare the reviewed new feed with:

```powershell
python -B scripts/public-catalog-feed.py prepare --directory <reviewed-public-bundle> --output <isolated-feed-staging> --revision <new-unique-revision> --sequence <higher-sequence> --latest-name latest-v2.json --previous-manifest <latest-v1-or-v2-manifest>
```

The publisher rejects locker/expanded-scope data for `latest.json`. Existing imported/private locker evidence takes precedence over a public supplement. A missing value can be filled only for the same unambiguous property and nonconflicting source registry. Public records never become checked delivery doors or manifest stops. A locker marker is drawn only for an independently supported point.

The explicit 65-ZIP scope comes from Clark County OpenData `zip_p/MapServer/0` polygons intersecting the research envelope `-115.50,35.85,-114.85,36.50`, retrieved 2026-10-24. The polygon overlap includes fringe ZIPs and does not prove that every address in them belongs to a valley neighborhood.

## Retained public qualifications

Previously published directory-sector and estimated-area cohorts keep their original complete feature and source SHA-256 seals. The four `scripts/reviewed-*-features-20261023.json` files were copied byte-for-byte from the approved publisher metadata. Admission checks exact identity, coordinates, source records, qualification notes and complete alternate-side cohorts; they are not a general free-text exception. Earlier revisions may omit a cohort entirely.

The optional compatibility tests use `APARTMENTFINDER_PUBLIC_COMPAT_DIRECTORY` pointing at a manifest-bound public revision. No local user path or private pack is embedded in the tests.
