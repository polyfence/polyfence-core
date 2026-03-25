package io.polyfence.core

/**
 * Typed configuration for creating geofence zones.
 * Preferred over the raw Map-based addZone API.
 */
data class ZoneConfig(
    val id: String,
    val name: String,
    val type: GeofenceEngine.ZoneType,
    val center: GeofenceEngine.LatLng? = null,
    val radius: Double? = null,
    val polygon: List<GeofenceEngine.LatLng>? = null,
    val metadata: Map<String, String>? = null
) {
    companion object {
        /**
         * Create a circle zone configuration
         */
        fun circle(
            id: String,
            name: String,
            center: GeofenceEngine.LatLng,
            radius: Double,
            metadata: Map<String, String>? = null
        ): ZoneConfig {
            return ZoneConfig(
                id = id,
                name = name,
                type = GeofenceEngine.ZoneType.CIRCLE,
                center = center,
                radius = radius,
                metadata = metadata
            )
        }

        /**
         * Create a polygon zone configuration
         */
        fun polygon(
            id: String,
            name: String,
            polygon: List<GeofenceEngine.LatLng>,
            metadata: Map<String, String>? = null
        ): ZoneConfig {
            return ZoneConfig(
                id = id,
                name = name,
                type = GeofenceEngine.ZoneType.POLYGON,
                polygon = polygon,
                metadata = metadata
            )
        }
    }

    /**
     * Convert to the Map format used by the legacy addZone API
     */
    fun toMap(): Map<String, Any> {
        val map = mutableMapOf<String, Any>()
        when (type) {
            GeofenceEngine.ZoneType.CIRCLE -> {
                map["type"] = "circle"
                center?.let {
                    map["center"] = mapOf("latitude" to it.latitude, "longitude" to it.longitude)
                }
                radius?.let { map["radius"] = it }
            }
            GeofenceEngine.ZoneType.POLYGON -> {
                map["type"] = "polygon"
                polygon?.let { points ->
                    map["polygon"] = points.map { mapOf("latitude" to it.latitude, "longitude" to it.longitude) }
                }
            }
        }
        metadata?.let { map["metadata"] = it }
        return map
    }
}
