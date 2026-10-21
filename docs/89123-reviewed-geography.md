# Reviewed 89123 geography increment

This candidate combines the frozen Lyric/Trend community-location and compact-control repair with the completed 89123 research packages. The source basis is `ea20637c592c3e16b0edef368b6eb3790fff11ba`, which includes the frozen PR4 data. PR4 and PR5 remain unchanged.

The scope is the 31 existing catalog entries whose postal ZIP is 89123. It is not a census of every apartment in the ZIP. Nineteen entries now have some unit or building geography; twelve still lack it. Community locations, unit/building associations and floor-only facts do not count as verified delivery-door coverage.

| Evidence type | Added | Result |
| --- | ---: | --- |
| Community locations | 20 | Property areas only; four county Test-service address points retain their qualified source lineage |
| Published operator unit references | 502 | Prosper 150: 150; Summer Winds: 352. Floors and stable source IDs retained, including stacked coordinates |
| Approximate operator building areas | 62 | Pebble: 10; Parkside: 25 distinct roof lobes; Paramount: 27 |
| Qualified assessor/legal building areas | 84 | Southpark: 21; Loft 5: 8; Paragon: 8; Emerald: 10; Octave: 35; One Las Vegas: 2 |
| Unit/building associations | 1,092 | Pebble: 370; Summer Winds: 2; literal county joins: 456; qualified historical Octave aliases: 264 |
| Floor-only references | 359 | One Las Vegas; no unit-to-tower crosswalk or geographic unit destination |
| Verified doors or entrances | 0 | No door positions are fabricated |

Pebble has 416 literal schematic unit/building/floor associations: 46 existing exact identities and 370 additions. Floors contain 160, 160 and 96 labels. Unit lookup selects its linked approximate building area and source floor. The ten building markers use 20 m working uncertainty, which is not guaranteed accuracy. The published schematic inventory is not independently certified as current physical inventory.

Parkside's 25 roof lobes retain distinct occurrence IDs despite only 14 printed building badges. Loft 5 retains 272 full-address unit identities rather than collapsing them into 42 apartment-label strings. Octave's 264 historical legal aliases are explicitly labeled; only 16 have dated operator corroboration. Emerald's existing printed ranges remain unchanged and are not expanded. One Las Vegas's two tower areas are context only: apartment digits never assign a unit to a tower.

The map displays source unit references and qualified building areas separately from checked personal doors. One marker represents each linked building area. Stacked floors retain their coordinates and independent IDs; the focused marker is drawn above its siblings. Properties with only contextual areas still show those areas without inventing a unit destination.

## Preservation and resource boundaries

All original 14,772 location objects (including 14,517 unit positions), 687 source objects and 17 paths are preserved. All 6,923 prior associations retain their full identity and prior sources; 961 gain previously absent, reviewed metadata. Existing community names, addresses, ZIPs and aliases are preserved. Personal door precedence, imported generation selection and stored personal bytes are tested with invented local fixtures. Public supplements do not rewrite the private import or personal store.

The resulting resources contain 162 communities, 15,420 locations (15,019 unit positions, 339 legal building areas and 62 operator building areas), 8,015 associations and 752 sources. The catalog is 2,688,636 bytes. Only the dedicated compiled-public-catalog ceiling changes from 2,100,000 to 3,000,000 bytes. The 2,000,000-byte private/import and known-address boundaries, 64,000,000-byte locations boundary and 16,000,000-byte paths boundary are unchanged. Exact-boundary, oversize, symlink, malformed-schema and import-preservation checks remain enforced.

`89123-geography-preservation.json` enumerates the reviewed delta. Portable tests first verify each accepted new value and then reverse only that delta to recover hardcoded hashes of the frozen basis. Mutation cases reject original-coordinate, source, identity and unapproved-field changes. `89123-geography-source-facts.json` retains factual provenance; source artwork, aerials, delivery manifests and private fixtures are excluded from production assets.

## Validation scope

The exact-source public suite selects 142 Core, 71 native and eight UI cases, retaining all original public selectors and adding geography checks. UI acceptance covers actual Pebble camera/marker behavior, stacked-floor marker taps, recovered Summer Winds units, historical aliases, floor-only tower uncertainty, Lyric/Trend community centers, compact controls and the original map interaction case. The manual regression also builds the unsigned Release app and embedded Share extension, verifies identifiers, executables and every reviewed resource hash, and rejects signature bundles.

The original full inventory remains 86 native and 45 UI tests with the original 45-screenshot minimum. Private-fixture and installed-device coverage are separate and are not claimed by public-synthetic results. Load reports expose read/decode/validation and supplement medians separately. `processCumulativePeakRSSBytes` means process-wide cumulative peak RSS, not isolated dataset memory.

Candidate-specific test results belong to the PR and workflow run; this document does not attest release eligibility. The protected owner release workflow remains unchanged and requires the exact accepted main SHA before signing. No new credentials, paid runner, public testing audience or automatic release is introduced.

## Remaining gaps

`89123-catalog-geography-gaps.json` lists the twelve exact catalog names, addresses, checked source URLs and missing evidence. One Las Vegas remains partial because its unit-to-tower crosswalk is unavailable. No confirmed unextracted live operator unit map remains among the sources checked in this research pass. Missing evidence remains visible; this increment does not claim complete ZIP or verified-door coverage.
