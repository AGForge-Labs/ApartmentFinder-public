"""A changed old or newly admitted fact must fail before historical projection."""
import copy
import hashlib
import json
import unittest

from reviewed_bundle_history import historical_resources, load_reviewed_resources


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


class ReviewedBundleHistoryTests(unittest.TestCase):
    def test_sealed_current_bundle_projects_exact_shipped_objects_without_mutating_inputs(self):
        current = load_reviewed_resources()
        before = fingerprint(current)
        projected = historical_resources(current)
        self.assertEqual(fingerprint(current), before)
        expected = {
            "public-catalog.json": "61435e5c9f1a24e58229801db30e40e42e4e2425fa517fe10087b82ff0a19b29",
            "public-locations.geojson": "cf6985496ca75a80574a34ca78fdf0caef909e2acb58b8676bb5902bff316b3b",
            "public-paths.geojson": "c75ca228604c71e8ade140790dac4772978e9037ec4ccf54ecc71028a85e47e4",
            "known-addresses.json": "8eaf70dfdb7aa3ba294b9525793a74070772b7b6d001065655cd6ff7cc245628",
        }
        self.assertEqual({name: fingerprint(value) for name, value in projected.items()}, expected)
        self.assertEqual(len(current["public-catalog.json"]["communities"]), 186)
        self.assertEqual(len(current["public-locations.geojson"]["features"]), 23533)
        self.assertEqual(len(projected["public-catalog.json"]["communities"]), 162)
        self.assertEqual(len(projected["public-locations.geojson"]["features"]), 16064)

    def test_projection_rejects_old_and_new_coordinates_sources_identity_and_qualifications(self):
        original = load_reviewed_resources()
        for case in ("old-coordinate", "new-coordinate", "old-source", "new-source", "old-identity",
                     "patched-identity", "new-identity", "old-qualification", "new-qualification", "locker-qualification"):
            with self.subTest(case=case):
                changed = copy.deepcopy(original)
                catalog = changed["public-catalog.json"]
                features = changed["public-locations.geojson"]["features"]
                if case == "old-coordinate": features[0]["geometry"]["coordinates"][0] += 0.001
                elif case == "new-coordinate": features[16064]["geometry"]["coordinates"][0] += 0.001
                elif case == "old-source": catalog["sources"][0]["title"] += " changed"
                elif case == "new-source": catalog["sources"][778]["title"] += " changed"
                elif case == "old-identity": catalog["communities"][0]["address"] = "999 Other Street"
                elif case == "patched-identity":
                    next(c for c in catalog["communities"] if c["id"] == "rancho-serene")["address"] = "999 Other Street"
                elif case == "new-identity": catalog["communities"][162]["address"] = "999 Other Street"
                elif case == "old-qualification":
                    next(f for f in features[:16064] if f["properties"].get("entranceSideEstimate"))["properties"]["notes"] += " changed"
                elif case == "new-qualification": features[16064]["properties"]["notes"] += " changed"
                else:
                    next(c for c in catalog["communities"] if c["id"] == "rancho-serene")["digitalLocker"]["sourceIDs"] = []
                with self.assertRaisesRegex(AssertionError, "reviewed|sealed|metadata"):
                    historical_resources(changed)

    def test_projection_rejects_deleted_reordered_and_unapproved_new_facts(self):
        original = load_reviewed_resources()
        for case in ("deleted", "reordered", "private-field", "extra-community", "unknown-catalog-field"):
            with self.subTest(case=case):
                changed = copy.deepcopy(original)
                features = changed["public-locations.geojson"]["features"]
                if case == "deleted": features.pop()
                elif case == "reordered": features[-1], features[-2] = features[-2], features[-1]
                elif case == "private-field": features[-1]["properties"]["gateCode"] = "fictional-forbidden"
                elif case == "extra-community": changed["public-catalog.json"]["communities"].append(copy.deepcopy(changed["public-catalog.json"]["communities"][-1]))
                else: changed["public-catalog.json"]["unapprovedField"] = True
                with self.assertRaisesRegex(AssertionError, "reviewed|sealed|metadata"):
                    historical_resources(changed)

    def test_projection_rejects_unreviewed_version_date_and_scope(self):
        original = load_reviewed_resources()
        for key, value in (("packVersion", "unreviewed"), ("generatedAt", "2099-01-01"), ("scopeZIPs", ["90210"])):
            with self.subTest(field=key):
                changed = copy.deepcopy(original)
                changed["public-catalog.json"][key] = value
                with self.assertRaisesRegex(AssertionError, "reviewed|sealed|metadata"):
                    historical_resources(changed)
