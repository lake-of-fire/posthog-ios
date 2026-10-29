# PostHog Events: lake-of-fire fork

This fork provides an explicit-event-only SwiftPM product, `PostHogEvents`.
It is based on PostHog iOS **3.92.5**. It is a distinct, smaller API, not a
drop-in replacement for the full `PostHogSDK` interface.

## Package boundary

The package compiles the source list in `package-sources.json`: ten unchanged
upstream persistence, serialization, UUID and utility files, plus five fork
sources. Upstream Swift sources are not edited. `PostHogCapturedEvent` is an
internal capture envelope containing only event name, distinct ID, properties,
timestamp and UUID. The upstream `PostHogEvent` class, its replay-only state,
and its known-event inventory are excluded from the product.

`PostHogEventsQueue` owns capture scheduling over the unchanged upstream
`PostHogFileBackedQueue` FIFO. It preserves synchronous durable admission,
bounded batches, stable event UUIDs, retry and `Retry-After` handling, adaptive
HTTP 413 batch shrinking, and exact-entry acknowledgement. Restoring with a
smaller capacity trims old events first. The upstream generic queue, endpoint
registry, reachability observer and multicast callbacks are excluded. There is
no substitute `PostHogConfig` type or production call to a testing switch.

Neither optional SDK targets nor external package dependencies are present.
The compiled product excludes replay, screenshots, private UIKit/SwiftUI class
inspection, swizzling, autocapture, surveys, feature flags, remote configuration,
logs, push instrumentation, tracing and crash reporting. It does not link
libwebp, PLCrashReporter, or the Objective-C exception helper.

Those upstream directories remain in Git to make upstream merges ordinary
three-way merges. Their presence in this repository does not put them in the
SwiftPM product. The old Xcode project, podspec, root Makefile, and upstream
release workflows are preserved upstream material, **not supported fork
distribution paths**. Consume this fork through its SwiftPM manifests.
This fork does not provide the full SDK's Objective-C event model or callback API.

## Usage

Depend on this repository at an exact reviewed revision and select its
`PostHogEvents` product. Import the same module:

```swift
import PostHogEvents

let configuration = try PostHogEventsConfiguration(
    projectToken: "phc_your_project_token",
    storageDirectory: applicationSupport.appendingPathComponent("Analytics")
)
let analytics = try PostHogEventsClient(configuration: configuration)
analytics.capture("reader_opened", properties: ["chapter": 2])
analytics.flush() // requests a batch; it does not synchronously wait for upload
```

Keep one client alive for each storage directory. Use different directories
for different tokens **and hosts**. The storage identity validates both; a
mistaken reuse throws rather than uploading another project's queue. Opening also
throws if the queue directory cannot be created or enumerated; after the storage
problem is repaired, opening the same directory can be retried. Capture-time disk
write failures still return `false`. Multiple processes/app extensions must use
separate directories. `close()` stops timers
and uploads; the live instance continues to reserve its directory until deinit.
Pending records remain on disk. For local withdrawal/deletion, call
`try await analytics.closeAndDeleteStorage()` instead. It closes the delivery
gate, cancels transport, joins retiring queue work and removes owned queue/identity
storage without a final flush. Late responses cannot acknowledge or recreate
storage. Release the closed client before opening a replacement.
`PostHogEventsClient.deleteStorage(configuration:)` removes unopened storage
without starting a client and refuses a directory owned by a live client.
Neither method deletes events already received by a server.
A new installation can use
`bootstrapAnonymousID` to preserve a previously persisted UUID; existing fork
identity always wins over the bootstrap value.

Capture returns after its bounded event has been persisted, or returns `false`
for invalid input, oversize records, closed state or disk failure. Capacity is
1,000 events by default, at most 16 KiB per captured event; oldest events are
evicted at capacity. Defaults are batches of 50, threshold 5, timer 10 seconds.
Transient failures keep the same UUIDs on disk. A flush requests a batch and
honors backoff; the timer or subsequent flushes process later batches. Terminal
HTTP errors and singleton HTTP 413 records follow upstream's drop policy.
The production queue starts an idempotent dispatch-source timer on its utility
worker, independent of the main runloop. Stopping is final: no later timer,
queued flush or late response can start delivery or acknowledge stored events.
Transient responses retain entries with bounded linear backoff (1–30 seconds),
with `Retry-After` as a floor; the timer and explicit flush both honor it.

Storage keeps the previous fork's five-field JSON envelope and FIFO filenames;
no migration or new event IDs are needed when reopening an existing fork queue.
Restoration requires valid event/identity/properties/time/UUID fields. Malformed
envelopes are discarded as individual entries instead of synthesizing a new
deduplication ID or capture time. Upstream v2 event-model fallback formats are
not needed for storage created by this fork. No replay routing token is read or
written on an event; the project token belongs only to the batch request.

Only caller-supplied properties and library/session context are included.
There is no environment/device inspection or automatic event capture.
`$process_person_profile` and `$is_identified` are forced to `false`; reserved
`$...` event names are rejected. A random installation ID is persisted, so
events are pseudonymous. Sessions rotate on process launch, thirty minutes of
inactivity, or clock rollback. Responses control delivery status/backoff only;
their bodies cannot enable features or install integrations. Cookies, caches
and redirects are disabled for uploads. Apps still own consent, disclosures,
retention, deletion and the contents of explicit properties.

## Validation

Use a Swift 6+ test toolchain; the library uses Swift 5 language mode and keeps
upstream's Apple deployment minima. From the repository root:

```sh
make -f LakeOfFire/Makefile audit
make -f LakeOfFire/Makefile test
make -f LakeOfFire/Makefile build
```

`audit` inspects SwiftPM's actual target graph, verifies the source allowlist,
and lints admitted imports/dynamic runtime entry points. Behavior tests exercise
real fork queue/upstream persistence transitions and mock URLSession transport;
they never send events to PostHog. Build/test output passes through `xcsift`
with failure propagation. Set `SCRATCH=/path/outside/repository` to use a
different build cache. No build cache belongs in committed source or evidence.
The suites cover JSON identity/time/property roundtrips, malformed storage,
durable restoration into actual batch HTTP bodies, timer-driven delivery and
retry without explicit flush, exact-entry acknowledgement under capacity
replacement, adaptive/singleton 413, close-before-start, late completions and
concurrent purge/capture. Injected transports and URLProtocol fixtures keep
these tests entirely local.

## Updating upstream

1. Fetch upstream tags and merge the chosen stable release into
   `lake-of-fire/events-only` with `git merge --no-commit --no-ff <tag>`.
2. Resolve manifest conflicts by running
   `python3 LakeOfFire/scripts/render-manifests.py`, then stage both generated
   manifests. Keep the fork banner in the root README. Keep the obsolete full
   SDK `Package.resolved` absent; the fork has no external package dependencies.
3. Review upstream changes to the admitted utilities and the queue merge
   boundary below. Do not expand `package-sources.json` automatically.
   Excluded optional-feature files merge normally without fork edits.
4. Run the three validation commands and an iOS/Catalyst build. Inspect the
   resulting package/binary boundary before shipping. Commit the merge signed.
5. Update the consuming app's exact revision only after qualification.

Changes to package behavior belong under `LakeOfFire/`; the template is the
source of truth for both root manifests. The package audit fails on unexpected
targets, dependencies, new imported frameworks, or dynamic selector/class
lookup in admitted source. It supplements review; it is not an Apple approval
guarantee.

The generated manifests contain literal paths and perform no filesystem reads.
This supports Tuist/SwiftPM evaluators that load manifest text without the
original `#filePath`. Regenerate after merging upstream so the exclusion list
also accounts for new repository inputs; new source files remain unadmitted
until deliberately added to `package-sources.json`.

### Queue merge boundary

The upstream `PostHogQueue.start` currently requires the internal
`disableReachabilityForTesting` / `disableQueueTimerForTesting` switches and
the generic queue depends on SDK configuration and endpoint policies. An
unchanged admission cannot provide this fork's production lifecycle boundary.
The fork therefore owns the small capture scheduler, not the disk FIFO or a
second app uploader. `PostHogEventsQueue.swift` derives its delivery decisions
from upstream `PostHogQueue.swift` at this fork's base version. When merging:

- Compare `add`, `take`/`consume` and `handleResult` with the fork scheduler.
  Preserve synchronous admission, one in-flight batch, FIFO snapshots,
  exact-file-ID acknowledgement, durable transient retention and 413 limits.
- Review `PostHogFileBackedQueue`, `PostHogLegacyQueue`, `PostHogUploadInfo`,
  date/JSON/UUID/file utilities directly; these remain unchanged admissions.
  The legacy-queue helper is required by the upstream FIFO's implementation;
  the fork supplies no legacy migration directories.
- Review timer/stop fixes for the dispatch-source lifecycle and the delivery
  gate. Do not reintroduce reachability, replay prefix grouping, log rate caps,
  endpoint registration, SDK configuration adapters or test-only startup.
- Run the behavior suites above and the package audit. The audit's actual
  source graph is checked against the allowlist; scans alone do not establish
  archive exclusion.

## Upstream specification scope

This subset follows the wire shape and retained queue behavior described in
PostHog's [capture](https://github.com/PostHog/sdk-specs/blob/main/openspec/specs/capture/spec.md),
[event batcher](https://github.com/PostHog/sdk-specs/blob/main/openspec/specs/event-batcher/spec.md),
[persistent storage](https://github.com/PostHog/sdk-specs/blob/main/openspec/specs/persistent-storage/spec.md),
[retry queue](https://github.com/PostHog/sdk-specs/blob/main/openspec/specs/retry-queue/spec.md)
and [HTTP client](https://github.com/PostHog/sdk-specs/blob/main/openspec/specs/http-client/spec.md)
specifications, with the additional local-erasure barrier described above.
Unlike upstream shutdown, erasure never attempts a final flush. The app owns
persisted opt-in policy (see the upstream opt-in/opt-out specification); the
fork exposes storage erasure rather than adding a second consent setting.
It intentionally omits identification, profiles, registered
properties, automatic context, reachability monitoring and optional features.
It does not claim full PostHog client-SDK conformance. It relies on URLSession
failures and the fork retry timer when connectivity is unavailable. Connectivity
is unknown to the queue; it installs no reachability observer. The timer runs on
a utility dispatch queue instead of the upstream main runloop. Shutdown/erasure
do not flush. The fork also intentionally stamps anonymous/profile/library/
session properties after caller properties, differing from the full client
capture spec's caller-wins policy. Retained retry scheduling follows upstream's
linear backoff without jitter; the retry spec now recommends jitter. None of
these choices enables remote configuration or optional SDK behavior.

The upstream MIT license, third-party notices and original file headers remain
in place. This fork is not an official PostHog release and is not published to
upstream CocoaPods or PostHog's release channels.
