# iOS CLLocationManager Run-Loop Bug — Post-Mortem

The canonical, full-length incident report for this fix lives in the
internal docs repository:

**`polyfence-internal/docs/POSTMORTEM_IOS_CLLOCATIONMANAGER_RUNLOOP_2026-05-26.md`**

## Quick context for PR reviewers

On iOS, `CLLocationManager` delivers its async delegate callbacks
(`didUpdateLocations`, `didChangeAuthorization`, `didFailWithError`, etc.)
via the run loop of the thread on which the manager was created.

React Native 0.76+ in Bridgeless / New Arch dispatches `RCTEventEmitter`
method invocations — including `PolyfenceModule.initialize()` and therefore
`LocationTracker()` — on a runloop-less background dispatch queue. The
manager constructed in that environment can't deliver async callbacks;
iOS queues them and eventually discards them with the signatures
`Location callback block not executed in a timely manner` and
`Discarding message for event because of too many unprocessed messages,
count:N`.

Flutter does not hit this because `FlutterMethodChannel` dispatches on
a thread that has a run loop.

## The fix

In `setupLocationManager()`, force `CLLocationManager` construction onto
main with `DispatchQueue.main.sync` (not `.async`, because `startTracking()`
relies on `locationManager` being non-nil immediately after `init()` returns).
A `PF-THREAD setupLocationManager isMain=%{public}d` diagnostic os_log
line confirms the guard fired in device logs.

## Verification

Proven in three rungs of isolated bench tests (pure-Apple probe app,
polyfence-core probe app with fix stashed, polyfence-core probe app with
fix in place) and validated end-to-end in the real `polyfence-qa`
React Native app under live driving with sustained location streaming
and two zone enter/exit events fired live. Full evidence in the
canonical document.
