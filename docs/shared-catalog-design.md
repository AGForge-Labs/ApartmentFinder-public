# Shared apartment catalog and corrected pins: proposed boundary

This is a design proposal after the existing fixes and validation. No backend, account, grant, upload or synchronization has been created.

## Data separation

Keep the existing private map pack and personal-v1 store separate. A shared catalog can contain apartment/property identities, physical street addresses, public source evidence, map positions and explicitly reviewed building/unit identities. Driver-authorized pin corrections can contain only the chosen property/street/unit identity, coordinate, verification state, revision and correction provenance.

Do not share raw personal backups, free-text personal notes, customer or recipient data, deliveries/manifests, package identifiers, route history, GPS traces, gate/access codes, credentials or phone exports. A phone's edited pins remain local until the user authorizes a reviewed, field-limited sharing flow. Do not infer sharing permission from a pin's fieldVerified flag.

Preserve stable property IDs, physical street identity and distinct deliveries. Similar names and repeated unit labels must not merge properties. Existing personal corrections keep their priority and exact saved identity; catalog updates cannot overwrite them silently.

## Authorized drivers and offline use

Access should be limited to an explicitly approved driver group, enforced server-side. Distinguish reading approved catalog versions, proposing corrections and reviewing/publishing them. Account creation, grants, backend choice and any spending require a later decision.

Drivers continue using their last validated downloaded catalog and personal data offline. Save a correction locally first. A later authorized sync queues a field-limited proposal with an idempotency key and base revision. Failed/repeated uploads must not lose the local edit or create duplicate corrections. Revocation can stop future access; an offline device cannot be assumed to have erased its cached data immediately.

Download complete versioned pack generations, validate before activation and retain the previous generation for recovery. A partial/invalid update cannot replace the usable catalog or personal data. Keep routes and personal notes outside the shared payload.

## Conflict and review policy

Do not use silent last-write-wins for conflicting coordinates or identities. A proposal records its base revision, target identity, proposed position and provenance. Compatible replays are deduplicated; edits based on an older revision remain visible for review.

If two drivers disagree, preserve both proposals and the currently approved pin. A reviewer can accept one, reject it with a reason, or leave it unresolved. Large coordinate moves, property/street changes and uncertain building/floor changes require explicit review. Never invent certainty or an entrance based only on a unit label.

A driver can see their local correction immediately while the group keeps its approved version. An accepted revision must not erase unrelated personal work. Corrections should remain reversible with a bounded audit trail and explicit publication attribution.

## Validation before implementation

Use only fictional drivers, properties and coordinates to test offline/reconnect replay, duplicate proposals, simultaneous conflicting edits, stale revisions, revoked access, partial downloads, rollback and separate nearby properties. Privately verify the real phone's corrected pins survive the installed upgrade and any later catalog import before enabling sharing.
