# iOS CLLocationManager Run-Loop Bug — Post-Mortem

**Date:** 2026-05-26
**Branch / commit:** `fix/ios-clmanager-runloop` @ `50cc383`
**Severity:** Critical — every React Native consumer of polyfence-core on iOS would experience
silently frozen GPS after the first cached fix.
**Status:** Fixed and verified end-to-end in the real RN QA app under live driving.

---

## Summary

On iOS, the `CLLocationManager` inside `LocationTracker` was being constructed by the React Native
bridge on a runloop-less background dispatch queue. Apple's CoreLocation framework dispatches its
async delegate callbacks (`didUpdateLocations`, `didChangeAuthorization`, `didFailWithError`, etc.)
via the run loop of the thread on which the manager was created. With no run loop, iOS queued the
delegate invocations and silently discarded them after the buffer filled — logging
`Location callback block not executed in a timely manner` and
`Discarding message for event because of too many unprocessed messages, count:N` to the unified log.

The symptom was that an initial cached fix (returned synchronously from `manager.location`) flowed
correctly, but every subsequent `didUpdateLocations` was dropped. To a user driving with the app
open, GPS appeared frozen on the first reading — for hours, kilometres, indefinitely. iOS Flutter
was unaffected because `FlutterMethodChannel` dispatches plugin calls on a thread that does have
a run loop.

The fix forces `CLLocationManager` construction onto the main thread (which always has a run loop)
regardless of which bridge instantiates `LocationTracker`. One file changed, 28 lines added.

---

## Impact

| Surface | Affected? | Why |
|---|---|---|
| React Native consumers of `polyfence-core` on iOS | **Yes — all of them** | RN 0.76+ Bridgeless / New Arch dispatches `RCTEventEmitter` method invocations on a runloop-less background dispatch queue. `PolyfenceModule.initialize()` runs there, constructs `LocationTracker`, and the manager is born run-loop-less. |
| Flutter consumers of `polyfence-core` on iOS | No | `FlutterMethodChannel` dispatches plugin calls on a thread that has a run loop. |
| Android consumers (RN and Flutter) | No | Android's `FusedLocationProviderClient` does not have the equivalent dispatch model. |

User-observable behaviour on RN iOS prior to fix:
- App shows a single GPS reading on launch (the cached fix), then never updates.
- Zone enter/exit events never fire.
- No JS `onLocation` event after the first one.
- No error surfaced to the JS layer — the SDK appears healthy.

---

## Timeline (high level)

| When | What |
|---|---|
| Several days prior | Bug noticed in RN QA app. GPS freezes mid-drive. No useful error surfaced. |
| Earlier debugging attempts | Multiple speculative fixes attempted across `polyfence-qa`, `polyfence-react-native`, and `polyfence-core`. None made the symptom go away. Days were lost. |
| 2026-05-26 morning | Diagnosis narrowed to "callbacks stop after first fix" — classic Apple signature of `CLLocationManager` on a thread without a run loop. |
| 2026-05-26 09:00–10:00 | Rung-by-rung bench test plan written: prove in vacuum, prove in SDK, then fix. |
| 2026-05-26 ~09:10 | Rung 1 (raw `CLLocationManager` SwiftUI probe) — confirmed in vacuum. |
| 2026-05-26 ~09:30 | Rung 2 (polyfence-core's `LocationTracker` linked via local pod, fix temporarily removed via `git stash`) — bug reproduced inside the SDK. |
| 2026-05-26 ~09:48 | Rung 3 — fix committed on new branch `fix/ios-clmanager-runloop` @ `50cc383`, off `main`. |
| 2026-05-26 ~12:34 | Real RN QA app rebuilt & deployed against the new branch. `PF-THREAD setupLocationManager isMain=1` confirmed in device logs. |
| 2026-05-26 ~12:39–12:41 | Live driving test. Sustained location stream, two zone enter/exit events fired, no bug signatures observed. |
| 2026-05-26 ~12:50 | Cleanup: branch pushed, polygon WIP restored, probe apps deleted, post-mortem written. |

---

## The bug

### Apple's contract for `CLLocationManager` delegate dispatch

From Apple's documentation and observable behaviour: a `CLLocationManager` instance dispatches its
async delegate methods (`locationManager(_:didUpdateLocations:)`, `locationManager(_:didChangeAuthorization:)`,
`locationManager(_:didFailWithError:)`, etc.) by enqueuing them on the run loop of the thread that
called `CLLocationManager()`. If that thread has no run loop, the messages queue inside CoreLocation
and are eventually discarded under back-pressure.

Apple surfaces this in the unified log with two distinctive lines:

```
Location callback block not executed in a timely manner
Discarding message for event because of too many unprocessed messages, count:N
```

If you see those two lines in your app's syslog attributed to your app's process, you have this bug.

### Why it manifested in RN but not Flutter

React Native 0.76+ in Bridgeless / New Arch dispatches `RCTEventEmitter` method invocations on a
background dispatch queue by default. That queue's worker threads are short-lived `libdispatch`
worker threads with no `CFRunLoop` attached. When `PolyfenceModule.initialize()` runs on one of
those threads, every line inside it — including `LocationTracker()` → `setupLocationManager()` →
`CLLocationManager()` — runs on that thread. The manager attaches its delegate dispatch to that
thread's (non-existent) run loop. As soon as iOS tries to fire the first async delegate callback,
it can't and queues the message; subsequent messages compound until iOS gives up and discards them.

Flutter's `FlutterMethodChannel` does not exhibit this because by default plugin calls are
dispatched on a thread that does have a run loop. So the same `LocationTracker` code worked fine
in the Flutter QA app for months — masking the underlying fragility.

### Why earlier debugging missed it

The symptom (`first fix appears, then nothing`) does not look like a thread bug. It looks like a
distance-filter bug, a `pausesLocationUpdatesAutomatically` bug, a smart-GPS-profile bug, a
significant-location-change bug, or a permission bug. We chased all of those. The unique
signature that points at the run-loop cause —
`Location callback block not executed in a timely manner` + `Discarding message ... count:N`
in the unified log — was buried under thousands of unrelated CoreLocation system-service entries.
We only recognised it when we explicitly searched for the discard signature.

---

## Diagnosis methodology — the three rungs

The previous debugging approach (changing things across all three repos at once and rebuilding the
full RN app to test) had cost days without conclusive results. The replacement approach: **bench-test
one hypothesis in isolation, then climb the ladder of complexity one rung at a time.**

### Rung 1 — pure Apple API, zero polyfence code

A throwaway SwiftUI app (`~/Sector7/clprobe`) with a single file containing a raw
`CLLocationManager`. Two buttons:
- "Start on BACKGROUND queue" → instantiates the manager from `DispatchQueue.global().async`.
- "Start on MAIN thread" → instantiates from `DispatchQueue.main.async`.

The delegate updates an on-screen label with each location fix. NSLog mirrors the same to syslog.

**Result on physical iPhone 12 Pro Max:**
- BACKGROUND: tap, grant permission, screen stays `idle` indefinitely. No fixes delivered. Ever.
  (Stronger than the original hypothesis predicted — even the first async fix never arrived.)
- MAIN: tap, grant permission, screen shows coordinates within ~5 seconds and updates with GPS
  jitter while stationary.

**Verdict: the underlying mechanism is real and reproduces with zero polyfence code.**

### Rung 2 — same harness, swap in polyfence-core's `LocationTracker`

A second throwaway app (`~/Sector7/clprobe2`) with a `Podfile` referencing
`polyfence-core` as a local pod via `:path =>`. The harness wraps `LocationTracker` instead of
constructing a raw `CLLocationManager`. To prove the bug existed in the SDK code (not just in
vacuum), the in-progress fix was temporarily removed from `LocationTracker.swift` via
`git stash push -- ios/Classes/LocationTracker.swift`.

**Result with fix stashed:**
- BACKGROUND: `LocationTracker.init()` ran on the background queue; harness showed
  `tracker created on BACKGROUND, fix count 0` forever. No delegate callbacks reached the SDK.
- MAIN: `LocationTracker.init()` ran on main; harness incremented `fix count` and showed
  coordinates immediately; a planet-sized circle "probe-zone" even fired its `onGeofenceEvent`.

**Verdict: the bug manifests inside `polyfence-core`'s `LocationTracker` when the bridge calls
`init()` from a background queue — which is exactly what `PolyfenceModule.initialize()` does
under RN 0.76+ Bridgeless / New Arch.**

### Rung 3 — restore the fix and verify

The stashed fix was popped. The fix is a four-line additive guard at the top of
`setupLocationManager()`:

```swift
if !Thread.isMainThread {
    DispatchQueue.main.sync { self.setupLocationManager() }
    return
}
os_log("PF-THREAD setupLocationManager isMain=%{public}d", Thread.isMainThread ? 1 : 0)
locationManager = CLLocationManager()
```

Plus a documented comment block above the guard explaining the rationale (~22 lines).

**Result with fix in place, on the same probe harness:**
- BACKGROUND init now also delivers fixes — exactly as MAIN does — because the guard bounces
  execution to main before `CLLocationManager()` is called.
- `os_log` line `PF-THREAD setupLocationManager isMain=1` visible in syslog.

The fix was committed on a new branch `fix/ios-clmanager-runloop` off `main` (not off the polygon
WIP branch) so it can be reviewed as an isolated single-purpose change.

### Real-app validation

After all three rungs proved the hypothesis and the fix, the real RN QA app
(`polyfence-qa/react-native`) was rebuilt against `fix/ios-clmanager-runloop` and deployed to the
physical iPhone. With Location=Always, Motion, and Notifications granted, the user drove a normal
route over ~7 minutes. Observed in device syslog:

| Signal | Count | Significance |
|---|---|---|
| `PF-THREAD setupLocationManager isMain=1` | 2 | Once per PID — including a fresh process spawned by a background-wake mid-drive |
| `locationManagerDidChangeAuthorization:` delegate invoked | 2 | First async delegate callback path, the one the bug used to drop |
| `didUpdateLocations:` delegate invoked | ~25 | ~3/sec sustained during motion |
| `emit name=onLocation` | ~25 | 1-to-1 with delegate, JS receiving every fix via `RCTDeviceEventEmitter` |
| `emit name=onGeofenceEvent` | 2 | Two zone enter/exit boundary crossings fired live |
| `Discarding message ... unprocessed messages` | **0** | The bug signature, never seen |
| `Location callback block not executed in a timely manner` | **0** | The bug signature, never seen |

---

## The fix — what changed

`ios/Classes/LocationTracker.swift`, single file, additive only:

1. `import os` added at top (for `os_log`).
2. At the top of `setupLocationManager()`: a thread-check guard that uses
   `DispatchQueue.main.sync` (not `.async`) to re-enter on the main thread, then returns.
3. Immediately after the guard: `os_log("PF-THREAD setupLocationManager isMain=%{public}d", ...)`
   as diagnostic forensics so the fix is visible in device logs — and any future regression
   would be detectable in user-collected logs.
4. A documented comment block above the guard explaining the Apple contract, the RN-vs-Flutter
   asymmetry, why `.sync` (not `.async`), and the smoking-gun log lines to watch for if the
   condition recurs.

### Why `DispatchQueue.main.sync` and not `.async`

Callers of `LocationTracker.init()` (including `startTracking()` and the rest of the public API)
assume `self.locationManager` is non-nil the moment `init()` returns:

```swift
public func startTracking() {
    guard locationManager != nil else {
        os_log("startTracking ABORT: locationManager is nil", log: pfCoreLog, type: .error)
        return
    }
    // ...
}
```

If the fix used `.async`, `init()` would return immediately, `startTracking()` would observe a
still-nil `locationManager`, and the guard would abort the tracking start. `.sync` blocks the
calling thread until main has finished constructing the manager, preserving the init contract.
Deadlock risk is eliminated by the `if !Thread.isMainThread` check that gates the dispatch — if
init was already called on main, we never call `.sync` from main.

### Why `os_log` and not `NSLog` for the marker

In iOS 15+ release builds, `NSLog` arguments are redacted by default and appear in the unified
log as `<private>`. The first version of the fix used `NSLog` and the marker line showed up as
`May 26 12:20:29 PolyfenceTestApp(Foundation)[1058] <Notice>: <private>` — not useful for
verification or incident response. Switching to `os_log` with the `%{public}d` format specifier
opts out of redaction for this single non-sensitive integer field, and the line now appears
verbatim in `idevicesyslog` and Console.app.

---

## Lessons learned

### Engineering process

1. **When you've changed things across multiple repos and still can't reproduce in a known-good
   state, you have lost the experiment. Stop and re-isolate.** The previous days of debugging
   touched `polyfence-qa`, `polyfence-react-native`, and `polyfence-core` simultaneously. There
   was no longer a baseline to A/B against. The three-rung approach worked specifically because
   each rung was an isolated A/B test with one variable changed.

2. **Build a throwaway test app instead of changing production code to test a hypothesis.** Rungs
   1 and 2 took ~30 minutes each to write, build, sign, and deploy. The same hypothesis would
   have taken hours to test inside the QA RN app and would have left residue (modified files,
   stale builds, drifted branches) regardless of result.

3. **Reproduce the bug in vacuum BEFORE you fix it.** Rung 1 with no polyfence code proved the
   underlying Apple-API mechanism. Without that, the fix in `polyfence-core` would have been a
   plausible-looking change with no way to know if it addressed the actual root cause.

4. **`git stash` is the right tool to test pre-fix state of a working tree that already contains
   a candidate fix.** This let us run Rung 2 with the same SDK code that was about to be
   committed, minus only the thread guard, without losing the rest of the polygon-validation WIP.

5. **Branch the fix off `main`, not off the in-flight feature branch.** The runloop fix is a
   single-purpose, single-file, additive change that should be reviewable independently of the
   polygon-validation and cached-reconcile work. Branching off `main` keeps `fix/ios-clmanager-runloop`
   as a clean PR that can be merged on its own.

### Apple platform

6. **`CLLocationManager` is not safe to construct on a thread without a run loop.** The Apple
   docs say "the location manager calls these methods on the thread on which you initially
   initialized it" but does not loudly say "and that thread must have a run loop." Treat any
   foundation type with async delegate callbacks the same way: assume it needs the construction
   thread to have a run loop.

7. **`DispatchQueue.global()` workers have no run loop. Neither do RN's New-Arch
   `RCTEventEmitter` invocation queues. The main thread always does.** When in doubt, force
   creation onto main.

8. **Flutter and React Native do not have equivalent threading models for plugin invocation,
   even when the underlying SDK code looks identical. Test on both bridges.** The same
   `LocationTracker` code that had been working in Flutter for months was completely broken in
   RN because of a difference in how the bridges dispatch to plugins.

### Diagnostics

9. **Make critical thread-state markers survive release-build privacy redaction.** Use
   `os_log` with `%{public}…` for any short, non-sensitive diagnostic field whose absence
   from device logs would block incident response. Reserve `NSLog` for development.

10. **The two smoking-gun log lines for this bug are worth memorising:**
    - `Location callback block not executed in a timely manner`
    - `Discarding message for event because of too many unprocessed messages, count:N`

    If you see either of those in an app's unified log attributed to your app's process, you
    have a CoreLocation (or other async-delegate) manager constructed on a thread without a
    run loop. Don't waste time looking elsewhere.

11. **Use `idevicesyslog -p <ProcessName>` to filter by app process. Use `-e` to exclude noisy
    system processes.** The first attempt at live monitoring drowned in `nearbyd`, `wifid`,
    `locationd`, `navd`, and similar system-service CoreLocation logs. Process-name filtering
    cut the volume by ~99% and made the relevant signal trivially visible.

### Repository hygiene

12. **A long-running session with active WIP across multiple repos benefits from `git worktree`.**
    The fix branch was created and committed in a separate worktree
    (`polyfence-core-postmortem`) without disturbing the polygon-WIP branch's working tree.

---

## Prevention

Concrete actions to prevent recurrence or speed detection if it does recur:

1. **Done in this commit:** `os_log("PF-THREAD setupLocationManager isMain=%{public}d", ...)`
   inside `setupLocationManager()` so any regression is immediately visible in device logs.

2. **Done in this commit:** A 22-line comment block above the thread guard explaining the
   Apple contract, the RN-vs-Flutter asymmetry, and the bug signatures. Future engineers who
   try to "clean this up" will see exactly why the guard is necessary before they remove it.

3. **Recommended follow-up:** Add a CI smoke test on a physical iOS device (or at least a
   simulator scripted to deliver synthetic location updates) that exercises the RN bridge
   construction pattern. If the bug returns, CI catches it before the next release.

4. **Recommended follow-up:** For any other Apple foundation type added to `polyfence-core`
   in the future that has async delegate callbacks (`CMMotionActivityManager`,
   `CMPedometer`, `CMAltimeter`, etc.), apply the same thread guard pattern. Consider extracting
   a single helper:

    ```swift
    /// Run the closure on main, blocking if necessary. Safe to call from any thread.
    private func onMainSync<T>(_ block: () -> T) -> T {
        if Thread.isMainThread { return block() }
        return DispatchQueue.main.sync(execute: block)
    }
    ```

   and use it consistently at every Apple-foundation-type construction site.

5. **Recommended follow-up:** Document in `CONTRIBUTING.md` (or equivalent) the rule:
   *"Construct any CoreLocation, CoreMotion, or CoreBluetooth manager on the main thread.
   Bridges may call into us on arbitrary threads."*

---

## What lives where after this work

| Path | State |
|---|---|
| `polyfence-core` (primary checkout) | Branch `fix/ios-polygon-validation-and-cached-reconcile` with the original polygon-validation / cached-reconcile WIP restored from stash. Untouched relative to start of session. |
| `polyfence-core`, branch `fix/ios-clmanager-runloop` | One commit ahead of `main`: this fix at `50cc383`. Pushed to `origin`. PR-ready. |
| `polyfence-react-native` | Branch `fix/ios-emit-via-rctdevice-event-emitter` (WIP, separately tracked event-delivery fix). Untouched. |
| `polyfence-qa/react-native` | `Podfile` and `Pods/` reflect polygon-branch `polyfence-core` (1.0.8 + WIP). Installed iPhone binary is from the runloop-branch build — rebuild via `make rn-ios-build-release && make rn-deploy-ios` to align device with polygon branch when ready. |
| `~/Sector7/clprobe`, `~/Sector7/clprobe2` | Deleted. Apps uninstalled from iPhone. |

---

## Credits

Bench-test plan and rung-by-rung methodology proposed by the user. Execution and verification
performed in pair with the AI assistant over the morning of 2026-05-26. Final live drive test on
a public road in compliance with the user's local traffic regulations.
