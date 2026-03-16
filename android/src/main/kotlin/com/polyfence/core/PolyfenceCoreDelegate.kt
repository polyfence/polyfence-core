package com.polyfence.core

/**
 * Interface for platform bridges (Flutter, React Native, etc.) to receive
 * events from the core engine. Each bridge implements this interface.
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
}
