package io.polyfence.core.configuration

import org.junit.Assert.*
import org.junit.Test

/**
 * Unit tests for SmartGpsConfigFactory — the read/write shapes and the
 * BUG-015 merge behaviour.
 */
class SmartGpsConfigFactoryTest {

    // -------- toMap (BUG-014b: full 6-key display shape) --------

    @Test
    fun `toMap on a default config emits all six top-level keys`() {
        val map = SmartGpsConfigFactory.toMap(SmartGpsConfig())

        assertEquals(
            "toMap must include every top-level key regardless of instance state",
            setOf(
                "accuracyProfile",
                "updateStrategy",
                "enableDebugLogging",
                "proximitySettings",
                "movementSettings",
                "batterySettings"
            ),
            map.keys
        )
        // Null nested settings surface as default-constructed maps for
        // display, not as null / absent.
        assertTrue(map["proximitySettings"] is Map<*, *>)
        assertTrue(map["movementSettings"] is Map<*, *>)
        assertTrue(map["batterySettings"] is Map<*, *>)
    }

    // -------- toMergeBaseMap (BUG-015: sparse merge base) --------

    @Test
    fun `toMergeBaseMap omits null nested settings on a default config`() {
        val map = SmartGpsConfigFactory.toMergeBaseMap(SmartGpsConfig())

        assertEquals(
            "sparse variant must NOT materialise default-constructed nested blocks",
            setOf("accuracyProfile", "updateStrategy", "enableDebugLogging"),
            map.keys
        )
    }

    @Test
    fun `toMergeBaseMap includes nested settings only when set on the instance`() {
        val config = SmartGpsConfig(proximitySettings = ProximitySettings(nearZoneThresholdMeters = 42.0))
        val map = SmartGpsConfigFactory.toMergeBaseMap(config)

        assertTrue("configured nested block must appear", map.containsKey("proximitySettings"))
        assertFalse("null nested block must NOT appear", map.containsKey("movementSettings"))
        assertFalse("null nested block must NOT appear", map.containsKey("batterySettings"))
    }

    // -------- fromMap round-trip via toMergeBaseMap (BUG-015 merge simulation) --------

    @Test
    fun `partial update preserves the prior updateStrategy when only enableDebugLogging changes`() {
        // Reviewer's specific ask on 61cd2ac — the primary regression
        // scenario for BUG-015.
        val current = SmartGpsConfig(
            accuracyProfile = SmartGpsConfig.AccuracyProfile.MAX_ACCURACY,
            updateStrategy = SmartGpsConfig.UpdateStrategy.INTELLIGENT
        )
        val base = SmartGpsConfigFactory.toMergeBaseMap(current)
        val partial = mapOf<String, Any>("enableDebugLogging" to true)

        // Simulates what LocationTracker.updateConfigurationFromMap
        // does after this branch's fix.
        val merged = deepMergeSimulation(base, partial)
        val result = SmartGpsConfigFactory.fromMap(merged)

        assertEquals(SmartGpsConfig.UpdateStrategy.INTELLIGENT, result.updateStrategy)
        assertEquals(SmartGpsConfig.AccuracyProfile.MAX_ACCURACY, result.accuracyProfile)
        assertTrue(result.enableDebugLogging)
    }

    @Test
    fun `partial update against a config with no nested settings does not materialise nested blocks`() {
        // The 014b-vs-015 semantic regression this branch's second
        // commit fixes: toMergeBaseMap must NOT stuff default-
        // constructed nested settings into the merge base.
        val current = SmartGpsConfig(
            updateStrategy = SmartGpsConfig.UpdateStrategy.CONTINUOUS
        )
        val base = SmartGpsConfigFactory.toMergeBaseMap(current)
        val partial = mapOf<String, Any>("enableDebugLogging" to true)

        val merged = deepMergeSimulation(base, partial)
        val result = SmartGpsConfigFactory.fromMap(merged)

        // Instance stays null-nested — the runtime "feature inactive"
        // meaning is preserved.
        assertNull(result.proximitySettings)
        assertNull(result.movementSettings)
        assertNull(result.batterySettings)
    }

    @Test
    fun `partial nested update preserves untouched sub-fields inside the same nested block`() {
        val current = SmartGpsConfig(
            proximitySettings = ProximitySettings(
                nearZoneThresholdMeters = 100.0,
                farZoneThresholdMeters = 2500.0
            )
        )
        val base = SmartGpsConfigFactory.toMergeBaseMap(current)
        val partial = mapOf<String, Any>(
            "proximitySettings" to mapOf<String, Any>("nearZoneThresholdMeters" to 42.0)
        )

        val merged = deepMergeSimulation(base, partial)
        val result = SmartGpsConfigFactory.fromMap(merged)

        assertNotNull(result.proximitySettings)
        assertEquals(42.0, result.proximitySettings!!.nearZoneThresholdMeters, 0.0)
        assertEquals(
            "farZoneThresholdMeters must survive a partial nested update on nearZoneThresholdMeters",
            2500.0,
            result.proximitySettings!!.farZoneThresholdMeters,
            0.0
        )
    }

    // -------- helper --------

    /**
     * Mirror of the deepMergeMaps helper in LocationTracker.kt.
     * Duplicated here rather than exposed publicly so the merge tests
     * exercise the exact same semantics without expanding the public
     * API surface.
     */
    @Suppress("UNCHECKED_CAST")
    private fun deepMergeSimulation(
        base: Map<String, Any>,
        overrides: Map<String, Any>
    ): Map<String, Any> {
        val result = base.toMutableMap()
        for ((key, value) in overrides) {
            val existing = result[key]
            result[key] = if (existing is Map<*, *> && value is Map<*, *>) {
                deepMergeSimulation(existing as Map<String, Any>, value as Map<String, Any>)
            } else {
                value
            }
        }
        return result
    }
}
