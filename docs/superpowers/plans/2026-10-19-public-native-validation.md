# Public native validation preparation

Goal: prepare one manual, standard public Intel macOS runner using only explicitly selected synthetic tests, while retaining the separate private release gate.

Constraints: do not activate workflows, start jobs, sign, upload, release, use paid runners, import private packs or change application data. Existing app behavior stays unchanged unless a concrete regression is reproduced.

1. Add static integrity tests that reproduce the two empty fictional pack failures. Add one invented schema-valid location to each fixture. Preserve every existing behavioral assertion.
2. Reconcile the reviewed gate to the source inventory (74 native, 40 UI, 45 required screenshots), keeping exact-count and no-skip checks. Make artifact verifier unit tests use an isolated synthetic resource directory, rather than removed private repository data.
3. Prepare an exact synthetic test allowlist and an inactive manual-only macOS workflow. Reuse existing exact test identity/result verification. No cache, artifacts, credentials, private fixture inputs, release or TestFlight steps.
4. Run portable integrity, artifact verifier, iteration and proxy tests. Report Swift/Xcode and private-catalog acceptance as unrun.
5. Obtain independent review and return the prepared patch and the remaining private UI pack-bootstrap/installed-upgrade blockers for parent review.
