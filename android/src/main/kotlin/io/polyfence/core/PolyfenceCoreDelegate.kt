package io.polyfence.core

/**
 * Interface for platform bridges (Flutter, React Native, etc.) to receive
 * events from the core engine. Each bridge implements this interface.
 *
 * **Threading Contract:** All delegate callbacks are invoked on the main thread
 * unless otherwise noted. Implementations must not perform blocking operations
 * in callback methods. For long-running tasks, offload to background threads
 * (e.g., using coroutines or Handler.post).
 */
interface PolyfenceCoreDelegate {
    /** Called when a geofence event occurs (ENTER, EXIT, DWELL, RECOVERY_*) */
    fun onGeofenceEvent(eventData: Map<String, Any>)

    /** Called on each GPS location update */
    fun onLocationUpdate(locationData: Map<String, Any>)

    /** Called with runtime performance/health status */
    fun onPerformanceEvent(performanceData: Map<String, Any>)

    /** Called when an error occurs */
    fun onError(errorData: Map<String, Any>)

    /** Check if tracking is currently enabled in the bridge layer */
    fun isTrackingEnabled(): Boolean
}
