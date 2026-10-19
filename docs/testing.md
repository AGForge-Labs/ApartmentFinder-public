# Private acceptance inputs

Real-data core and native assertions require APARTMENTFINDER_PRIVATE_PACK_DIRECTORY, pointing outside this source tree to the genuine catalog.json, locations.geojson and paths.geojson. Supporting provenance assertions also use APARTMENTFINDER_PRIVATE_SOURCE_DIRECTORY. Missing required inputs fail clearly; a sample or skipped test is not acceptance.

Native tests must receive an accessible private fixture directory inside the authorized test environment. UI and update checks additionally need a genuinely installed private pack or legacy cache on that test installation. Do not put owner data in public source, workflow artifacts or logs.

Swift compilation, the private-input suites, folder-provider access, app-group sharing and protection, extension-before-main update behavior, search/route refresh, cancellation, responsiveness, recording/editor state and real-device upgrade remain unverified. The frozen earlier controller does not qualify changed source. Preserve its old evidence separately.

Safe source publication and app release have separate gates. Current local candidates have no active workflows or public Git history. Source provenance/privacy review must complete before publication; device signing and release require their own authorized validation.
