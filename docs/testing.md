# Validation boundaries

## Public synthetic check

The reviewed `.github/workflows/public-synthetic-check.yml` supports manual dispatch only. It requires an explicit approval input and the exact reviewed commit; source pushes do not start it.

It proposes one standard `macos-15-intel` job, manual dispatch only, with an exact reviewed commit, read-only repository permission, no saved credentials, no matrix, no cache or artifact upload, and a 35-minute ceiling. It explicitly checks Intel x86_64, selects Xcode 26.2 build 17C52 and the installed iOS 26.2 runtime, and refuses an image mismatch. It uses the production project specification and builds the app, Share extension and test targets for a disposable simulator. Simulator signing is ad-hoc; it uses no Apple account, distribution credentials or provisioning profile.

The exact source-checked allowlist in `scripts/public-synthetic-tests.json` selects:

- 88 synthetic core tests: parsing, duplicate deliveries, navigation, GPS freshness, initial framing, manual camera state, completion and rollback
- 60 synthetic native tests: personal storage, pack migration/failure, Finder independence, selection races, append, completion/undo, location and actual arrow rendering
- Two fictional OnTrac UI tests: ZIP preview/cancel/empty day, map display, pin-review cancellation, persistence and relaunch

All other core/native/UI tests remain present. The public check verifies exact passed test identities and rejects zero tests, failures, skips, expected failures, substitutions and missing selected methods. It cannot satisfy private acceptance or authorize release. It does not run the genuine catalog/property tests or the full private validation script.

Portable preparation checks:

```
python3 -B -m unittest discover -s Tests/public_synthetic -v
python3 -B -m unittest discover -s Tests/signing -v
python3 -B -m unittest discover -s Tests/iteration -v
node --test --test-reporter=tap services/geocoding/worker.test.mjs
```

Artifact verifier unit tests use isolated invented resource digests and simulated screenshots. They test the verifier, not a signed app or native behavior.

GitHub currently lists standard hosted runners as free for public repositories, including `macos-15-intel`: [official runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners). Larger/private runners are outside this proposal. Availability and image contents must be checked again before the first authorized run; see the [official image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md).

## Private acceptance and release

The current full source inventory is 75 native tests plus 40 UI tests, with 45 required screenshots. The old 68-native/108-total evidence is insufficient for this source. Source inventory, actual passed identities and result counts must agree, without skipped or substituted tests.

Real-data core and native assertions require `APARTMENTFINDER_PRIVATE_PACK_DIRECTORY`, pointing outside the public source tree to genuine `catalog.json`, `locations.geojson` and `paths.geojson`. Supporting provenance assertions also use `APARTMENTFINDER_PRIVATE_SOURCE_DIRECTORY`. Missing inputs must fail clearly. Synthetic output is not genuine catalog acceptance.

Remaining private-harness blockers:

- Retained JavaScript property/provenance suites still read removed in-tree `data/` and `research/` inputs. They need explicit private input routing before the full validator can run. Do not restore genuine files into this public checkout or run them in public Actions.
- Most real-property UI tests create a fresh `--test-store` but do not install the private pack into that store. An authorized private test environment needs an explicit isolated pack bootstrap before those cases run.
- `scripts/validate-ios.sh` exports complete result attachments and uses private-dependent suites. It must not be activated in public Actions.

Private acceptance must cover the real installed data, legacy pack and personal-store migration, extension-before-main upgrade, folder-provider access, app-group sharing/protection, search/route refresh, interrupted/cancelled imports, responsiveness, recording/editor state, personal pin corrections and real-device upgrade. Preserve the original phone installation and a verified private backup. Never distribute a blank-catalog or fictional-data build as an upgrade.

Swift compilation, simulator behavior and real-device upgrade have not been established by portable checks or source publication. Signed builds and TestFlight submission require their own authorization and validation.
