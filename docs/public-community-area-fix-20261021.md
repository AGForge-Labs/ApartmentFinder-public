# Lyric and Trend community map areas

This change is stacked on the unchanged PR #4 snapshot `bee0e05688a6e825c4938f6483169cd6fb8e536a`. It addresses the separately reported field failures at two distinct 89183 addresses.

| Property | Full street | Official community center (latitude, longitude) | Source |
| --- | --- | --- | --- |
| Lyric | 304 East Silverado Ranch Boulevard | 36.01408, -115.159018 | https://www.lyriclv.com/mapsanddirections |
| Trend! | 240 East Silverado Ranch Boulevard | 36.01422151644452, -115.16156023077903 | https://trendlv.com/ |

The Lyric directions-page property-map configuration publishes its center. Trend's official homepage publishes its point in its property JSON-LD. Both were retrieved and independently checked on 2026-10-21. The Lyric point was absent from the catalog; the Trend point was already present. Neither point is derived from the driver's location, an apartment number, or an operator-map pixel.

An installed imported community with no coordinates previously hid the public community area because the supplement retained its entire older community record. The projection now fills only an absent valid area for the same community ID and normalized full street, with its public provenance. Existing community coordinates and identities win. The imported generation and personal data are not rewritten. The regression also checks another street, conflicting source identity, invalid coordinates, a retained checked door, and an existing coordinate.

The mini-route renders these points as community areas, while retaining the missing-door count. The association warning now specifies that building and door locations are not mapped. An overview excludes a distant driver using the existing 750-meter initial-framing rule. A newly available area updates following/overview cameras without resetting a manual camera.

The floating controls were widened by the paused text label inside a shared capsule. Three separate 44-point icon targets now retain map type, overview and following actions, including the accessible “Resume following” label. Native UI tests measure their actual bounds in following and paused modes, check style and selected-stop preservation, and check the two community camera centers without creating door buttons. The existing pan, pin and map-style persistence regression remains in the focused native selection.

Lyric's 376 operator-map associations remain unchanged. Its official schematic supports unit 1193 in building 15 and unit 2171 in building 13. These labels establish no new floor, building coordinate, entrance or exact door. No new building-area reference or unit/door feature is added.

The [deterministic public geography inventory](public-community-geography-audit.json) covers every catalog community and separately counts community areas, qualified building references, source/estimated unit positions, verified public doors, and unit/building associations. It includes the five priority ZIP filters, including separately typed county ZIPs. Associations do not count as geographic coverage. Personal pins and private imports are excluded, and the audit does not establish complete ZIP coverage.

Regenerate with `python3 -B scripts/public-community-gap-audit.py --directory data --output docs/public-community-geography-audit.json`.

All 161 other community records, all original 686 source objects, all 6,923 associations, all 14,517 unit positions, all 255 approximate legal-building references and all 17 paths are retained. Only Lyric's area/provenance, the resource version metadata and corresponding review digests change in the data. Import size limits and schema 1 remain unchanged. No release approval, merge, signing, upload or audience change is part of this work.
