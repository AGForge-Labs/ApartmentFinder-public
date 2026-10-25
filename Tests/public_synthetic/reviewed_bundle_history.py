"""Test-only sealed inverse of the reviewed valley bundle's additive public delta.

This never supplies app data. All current prefixes, complete added suffixes and
metadata are checked before historical tests may remove the reviewed additions.
"""
import copy
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RESOURCE_NAMES = ("public-catalog.json", "public-locations.geojson", "public-paths.geojson", "known-addresses.json")
SEAL_SHA256 = "f3804100f8608db6888b6516d3c29e59eb071e43cda597bbe2732815eca1bf17"
PATCHED_COMMUNITIES = {"rancho-serene", "ascent-at-silverado", "revolution", "empire", "23twelve", "cyan-at-green-valley"}


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def load_reviewed_resources():
    return {name: json.loads((ROOT / "data" / name).read_bytes()) for name in RESOURCE_NAMES}


def historical_resources(current=None):
    """Validate the whole reviewed delta, then project exact current old objects.

    The input remains untouched. No old source, location, path, association or
    floor-reference object comes from a replacement fixture. Only six declared
    community source/locker enrichments and three metadata fields are reversed.
    The independent pre-existing historical hashes remain the final assertions.
    """
    seal_bytes = Path(__file__).with_name("reviewed-valley-history-seal.json").read_bytes()
    require(hashlib.sha256(seal_bytes).hexdigest() == SEAL_SHA256, "sealed historical projection declaration changed")
    seal = json.loads(seal_bytes)
    values = load_reviewed_resources() if current is None else current
    require(isinstance(values, dict) and set(values) == set(RESOURCE_NAMES), "reviewed resource set changed")
    for name in RESOURCE_NAMES:
        value, spec = values[name], seal["files"][name]
        require(isinstance(value, dict) and set(value) == set(spec["keys"]), "reviewed resource fields changed: " + name)
        require(all(value.get(key) == expected for key, expected in spec["reviewedMetadata"].items()),
                "reviewed metadata changed: " + name)
        for key, collection in spec["collections"].items():
            rows = value[key]
            count = collection["baselineCount"]
            require(isinstance(rows, list) and len(rows) == collection["reviewedCount"],
                    "sealed collection count changed: " + name + "/" + key)
            require(fingerprint(rows[:count]) == collection["reviewedPrefixSHA256"],
                    "sealed old prefix changed: " + name + "/" + key)
            require(fingerprint(rows[count:]) == collection["addedSuffixSHA256"],
                    "sealed complete added suffix changed: " + name + "/" + key)
    # Construct copies only after all current facts and full suffixes were admitted.
    result = {}
    for name in RESOURCE_NAMES:
        value, spec = values[name], seal["files"][name]
        result[name] = {key: copy.deepcopy(item) for key, item in value.items() if key not in spec["collections"]}
        for key, collection in spec["collections"].items():
            result[name][key] = copy.deepcopy(value[key][:collection["baselineCount"]])
    patches = seal["communityInversePatches"]
    require(set(patches) == PATCHED_COMMUNITIES, "sealed inverse community set changed")
    communities = {row["id"]: row for row in result["public-catalog.json"]["communities"]}
    for cid, patch in patches.items():
        require(set(patch) == {"restore", "remove"} and set(patch["restore"]) == {"sourceIDs"}
                and set(patch["remove"]) <= {"digitalLocker"}, "sealed inverse fields changed")
        communities[cid].update(copy.deepcopy(patch["restore"]))
        for key in patch["remove"]:
            del communities[cid][key]
    for name in RESOURCE_NAMES:
        spec = seal["files"][name]
        require(set(spec["baselineMetadata"]) <= {"packVersion", "generatedAt", "scopeZIPs"}, "sealed metadata inverse changed")
        result[name].update(copy.deepcopy(spec["baselineMetadata"]))
        for key, collection in spec["collections"].items():
            require(fingerprint(result[name][key]) == collection["baselineSHA256"],
                    "sealed historical collection changed: " + name + "/" + key)
        require(fingerprint(result[name]) == spec["baselineFileSHA256"], "sealed historical resource changed: " + name)
    return result
