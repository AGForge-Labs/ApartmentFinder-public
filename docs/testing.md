# Validation boundaries

## Public synthetic check

The reviewed `.github/workflows/public-synthetic-check.yml` supports manual dispatch only. It requires an explicit approval input and the exact reviewed commit; source pushes do not start it.

It uses one standard `macos-15-intel` job, manual dispatch only, with an exact reviewed commit, read-only repository permission, no saved credentials, no matrix, no cache or artifact upload, and a 90-minute hung-job timeout. It explicitly checks Intel x86_64, selects Xcode 26.2 build 17C52 and the installed iOS 26.2 runtime, and refuses an image mismatch. It uses the production project specification and builds the app, Share extension and test targets for a disposable simulator. Simulator signing is ad-hoc; it uses no Apple account, distribution credentials or provisioning profile.

The exact source-checked allowlist in `scripts/public-synthetic-tests.json` selects:

- 88 synthetic core tests: parsing, duplicate deliveries, navigation, GPS freshness, initial framing, manual camera state, completion and rollback
- 60 synthetic native tests: personal storage, pack migration/failure, Finder independence, selection races, append, completion/undo, location and actual arrow rendering
- Two fictional OnTrac UI tests: ZIP preview/cancel/empty day, map display, pin-review cancellation, persistence and relaunch

### Focused, text-only activation diagnosis

The manual `scope` input defaults to `regression`, preserving the selection above. The separate `activation-diagnostics` scope runs portable checks and exactly two existing test identities: `OnTracImportSetupTests/testFictionalPackAndExactZIPReachTheTwoDayImportRequestOnIOS` and `OnTracFlowTests/testSourceUnitPinAppearsOnMapAfterOnTracImport`. It does not freshly validate the other core/native/UI cases or satisfy full acceptance.

Only that scope forwards `TEST_RUNNER_APARTMENTFINDER_SYNTHETIC_DIAGNOSTICS=1` to XCTest; the focused UI test then explicitly enables app diagnostics with a valid isolated UUID store. This uses Apple's [documented test-runner environment forwarding](https://developer.apple.com/documentation/Xcode-Release-Notes/xcode-13-release-notes). App instrumentation is additionally restricted to DEBUG simulator execution.

If the original chooser is absent, the test saves and logs that original failure state, then tries the real production Import Manifest list button in a fresh UUID store with the same toolbar and no-pack inset. It observes picker-request/Cancel/dismissal state without selecting a file. A missing app accessibility Cancel control does not establish that the system picker is absent. Three bounded, main-actor samples also record whether a visible public `UIDocumentPickerViewController` was observed in this app's foreground scenes, without loading views or emitting controller details. This is a positive witness only: SwiftUI does not guarantee that UIKit hosting implementation, so a negative observation remains inconclusive.

The failure branch then makes a fresh-store toolbar comparison with only the visible no-pack banner's hit testing disabled, followed by another fresh-store unchanged toolbar baseline. The pass-through switch requires all existing simulator/DEBUG/isolated-store diagnostic gates and its exact allowlisted probe; ordinary no-pack interaction and release app behavior are unchanged. Each comparison uses one normal tap after unique/enabled/hittable checks and records the same fixed geometry. Baseline failure, pass-through success with matching geometry/action/fixture/request witnesses, and a repeated baseline failure support a banner hit-region cause more strongly than launch order alone. The comparison does not itself repair production layout. The original saved failure is still asserted and the caller returns; comparison success cannot make the original test pass. The embedded ZIP remains in app tmp, so this does not claim Files-provider selection or import coverage.

The app writes up to four small, fixed-schema scalar witnesses, one per allowlisted launch. The collector reads only those exact files inside the disposable simulator app container, rejects unexpected keys/types/enums, symlinks and files over 8 KiB, and emits only approved values. No customer data, catalog contents, error text, filenames, paths, UUIDs or GPS coordinates are emitted. Missing/invalid evidence is distinct from a valid zero count. An early zero snapshot is not conclusive proof that no later action ran: if every later write failed, its in-memory write-failure count could not reach disk. The independent toolbar/list AX comparison and recorded phases must be considered together. Logged screen rectangles describe UI geometry, not the actual injected tap coordinate.

Explicit test screenshot and unrestricted accessibility attachments are disabled in this scope. Xcode may still create internal ephemeral result attachments; none are exported or uploaded. There is no image/artifact upload path.

Diagnostic work has an 85-minute hung-work deadline measured from the first guard step, reserving approximately five minutes inside the 90-minute job timeout for cleanup. Initial guard/checkout/portable steps have diagnostic-only limits of 5/5/10 minutes, and preparation, simulator boot, native work and result processing share the work cutoff. Individual diagnostic tests have a 600-second execution allowance rather than the previous short allowance. Command termination, witness collection and simulator cleanup have bounded waits; original build failures are preserved, and cleanup failure cannot leave an otherwise successful check green. The reserve is a design budget, not an infrastructure timing guarantee. Normal regression mode also uses the practical 90-minute hung-job timeout. Jobs finish when their checks finish; these are safety limits, not target durations.

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

At commit `ef7f318b1fbd1ee992de315c2ffa82dca24463f0`, the public simulator run compiled the app, Share extension and test targets, and passed 88 core plus 60 native tests. The first selected UI case failed before its chooser appeared; the second started but had no recorded outcome when the run was cancelled near the configured time limit. Those results do not establish full UI or real-device upgrade acceptance. Signed builds and TestFlight submission require their own authorization and validation.
