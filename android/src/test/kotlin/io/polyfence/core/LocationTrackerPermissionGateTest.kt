package io.polyfence.core

import android.Manifest
import android.app.Application
import android.content.Context
import android.os.Build
import androidx.test.core.app.ApplicationProvider
import io.polyfence.core.utils.PolyfenceConfig
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Permission matrix for the tracker's start gate. Swift counterpart:
 * `test/ios/LocationTrackerPermissionGateTests.swift`.
 *
 * The property under test: base tracking is a foreground service and needs
 * only foreground location. `ACCESS_BACKGROUND_LOCATION` governs location
 * access outside a foreground service, which is what OS wake fences use and
 * nothing else in this library does — so it gates that feature, not the
 * product. iOS has always accepted "when in use" for base tracking; these
 * cases lock Android to the same contract.
 *
 * The gate is private, so the cases drive it by reflection. That is the exact
 * predicate `onStartCommand` and `startTracking` consult before refusing, so
 * asserting on it is asserting on whether tracking would start.
 */
@RunWith(RobolectricTestRunner::class)
class LocationTrackerPermissionGateTest {

    private lateinit var context: Context
    private lateinit var tracker: LocationTracker
    private val capturedErrors = mutableListOf<Map<String, Any>>()

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        PolyfenceConfig(context).resetToDefaults()
        capturedErrors.clear()
        PolyfenceErrorManager.initialize { capturedErrors.add(it) }
    }

    @After
    fun tearDown() {
        if (::tracker.isInitialized) tracker.onDestroy()
        PolyfenceErrorManager.dispose()
        PolyfenceConfig(context).resetToDefaults()
    }

    // ---------------------------------------------------------------
    // Fixtures
    // ---------------------------------------------------------------

    /** Builds the Service after config is staged, since onCreate reads it. */
    private fun startService(): LocationTracker {
        tracker = Robolectric.buildService(LocationTracker::class.java).create().get()
        return tracker
    }

    private fun grant(vararg permissions: String) {
        shadowOf(ApplicationProvider.getApplicationContext<Application>())
            .grantPermissions(*permissions)
    }

    private fun deny(vararg permissions: String) {
        shadowOf(ApplicationProvider.getApplicationContext<Application>())
            .denyPermissions(*permissions)
    }

    /** True when the tracker would agree to start with the current grants. */
    private fun wouldStartTracking(): Boolean {
        val method = LocationTracker::class.java.getDeclaredMethod("hasCoreTrackingPerms")
        method.isAccessible = true
        return method.invoke(tracker) as Boolean
    }

    private fun hasBackgroundGrant(): Boolean {
        val method = LocationTracker::class.java.getDeclaredMethod("hasBackgroundLocationPerm")
        method.isAccessible = true
        return method.invoke(tracker) as Boolean
    }

    private fun enableWakeFences() {
        PolyfenceConfig(context).osGeofenceWakeEnabled = true
    }

    // ---------------------------------------------------------------
    // Pre-Q: the background permission does not exist
    // ---------------------------------------------------------------

    @Test
    @Config(sdk = [Build.VERSION_CODES.P])
    fun `pre-Q starts on foreground location alone`() {
        grant(Manifest.permission.ACCESS_FINE_LOCATION)
        startService()

        assertTrue(wouldStartTracking())
        assertTrue("the permission has no meaning below Q", hasBackgroundGrant())
    }

    // ---------------------------------------------------------------
    // Q+ with wake fences off — the case that used to refuse
    // ---------------------------------------------------------------

    @Test
    @Config(sdk = [Build.VERSION_CODES.Q])
    fun `starts without background location when wake fences are off`() {
        // The whole point of the relaxation: a consumer running a foreground
        // service and never touching OS wake fences must not be forced through
        // Google Play's background-location review to use this library.
        grant(Manifest.permission.ACCESS_FINE_LOCATION)
        deny(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        startService()

        assertTrue(wouldStartTracking())
        assertFalse(hasBackgroundGrant())
    }

    @Test
    @Config(sdk = [Build.VERSION_CODES.Q])
    fun `starts on coarse location alone`() {
        grant(Manifest.permission.ACCESS_COARSE_LOCATION)
        deny(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_BACKGROUND_LOCATION
        )
        startService()

        assertTrue(wouldStartTracking())
    }

    @Test
    @Config(sdk = [Build.VERSION_CODES.Q])
    fun `refuses when no foreground location is granted`() {
        deny(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION,
            Manifest.permission.ACCESS_BACKGROUND_LOCATION
        )
        startService()

        assertFalse(wouldStartTracking())
    }

    // ---------------------------------------------------------------
    // Q+ with wake fences on
    // ---------------------------------------------------------------

    @Test
    @Config(sdk = [Build.VERSION_CODES.Q])
    fun `starts with wake fences on even when background location is denied`() {
        // Wake fences degrade; tracking does not. The consumer keeps the
        // product and gets a warning about the capability they lost.
        enableWakeFences()
        grant(Manifest.permission.ACCESS_FINE_LOCATION)
        deny(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        startService()

        assertTrue(wouldStartTracking())
        assertFalse(hasBackgroundGrant())
    }

    @Test
    @Config(sdk = [Build.VERSION_CODES.Q])
    fun `wake fences report denial through the health field and onError`() {
        enableWakeFences()
        grant(Manifest.permission.ACCESS_FINE_LOCATION)
        deny(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        startService()

        val registrar = OsGeofenceRegistrar(context, mockClient())
        registrar.onAppBackgrounded()
        registrar.refreshNowForTest(
            zones = listOf(
                GeofenceEngine.Zone(
                    id = "z1",
                    name = "Zone 1",
                    type = GeofenceEngine.ZoneType.CIRCLE,
                    center = GeofenceEngine.LatLng(51.5, -0.1),
                    radius = 250.0,
                    points = emptyList()
                )
            ),
            seed = null
        )

        assertEquals(
            OsGeofenceRegistrar.ERROR_BACKGROUND_LOCATION_DENIED,
            registrar.health!!.lastError
        )
        assertTrue(capturedErrors.any { it["type"] == "os_geofence_permission_denied" })
    }

    @Test
    @Config(sdk = [Build.VERSION_CODES.Q])
    fun `starts with wake fences on and background location granted`() {
        enableWakeFences()
        grant(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_BACKGROUND_LOCATION
        )
        startService()

        assertTrue(wouldStartTracking())
        assertTrue(hasBackgroundGrant())
    }

    // ---------------------------------------------------------------
    // API 34+ foreground-service permission
    // ---------------------------------------------------------------

    @Test
    @Config(sdk = [34])
    fun `refuses on API 34 without the foreground-service location permission`() {
        grant(Manifest.permission.ACCESS_FINE_LOCATION)
        deny(Manifest.permission.FOREGROUND_SERVICE_LOCATION)
        startService()

        assertFalse(wouldStartTracking())
    }

    @Test
    @Config(sdk = [34])
    fun `starts on API 34 with the foreground-service permission and no background grant`() {
        grant(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.FOREGROUND_SERVICE_LOCATION
        )
        deny(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        startService()

        assertTrue(wouldStartTracking())
    }

    // ---------------------------------------------------------------
    // Mid-session revocation
    // ---------------------------------------------------------------

    @Test
    @Config(sdk = [Build.VERSION_CODES.Q])
    fun `revoking background location mid-session leaves tracking running`() {
        enableWakeFences()
        grant(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_BACKGROUND_LOCATION
        )
        startService()
        assertTrue(wouldStartTracking())

        deny(Manifest.permission.ACCESS_BACKGROUND_LOCATION)

        // The health tick consults the core predicate to decide whether to stop.
        // Losing only the wake-fence grant must not take the product away.
        assertTrue(wouldStartTracking())
        assertFalse(hasBackgroundGrant())
    }

    @Test
    @Config(sdk = [Build.VERSION_CODES.Q])
    fun `revoking foreground location mid-session stops tracking`() {
        grant(Manifest.permission.ACCESS_FINE_LOCATION)
        startService()
        assertTrue(wouldStartTracking())

        deny(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION
        )

        assertFalse(wouldStartTracking())
    }

    @Test
    @Config(sdk = [Build.VERSION_CODES.Q])
    fun `revalidation reports the lost grant without attempting a registration`() {
        enableWakeFences()
        grant(Manifest.permission.ACCESS_FINE_LOCATION)
        deny(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        startService()

        // Registration attempts are driven by movement and zone changes, so a
        // stationary user would otherwise lose wake coverage with no signal.
        OsGeofenceRegistrar(context, mockClient()).revalidatePermission()

        assertTrue(capturedErrors.any { it["type"] == "os_geofence_permission_denied" })
    }

    private fun mockClient(): com.google.android.gms.location.GeofencingClient {
        val client = org.mockito.Mockito.mock(
            com.google.android.gms.location.GeofencingClient::class.java
        )
        org.mockito.Mockito.`when`(
            client.removeGeofences(
                org.mockito.ArgumentMatchers.any(android.app.PendingIntent::class.java)
            )
        ).thenReturn(com.google.android.gms.tasks.Tasks.forResult<Void>(null))
        return client
    }
}
