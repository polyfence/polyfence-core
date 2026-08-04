package io.polyfence.core

import android.Manifest
import android.app.Application
import android.content.Context
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import io.polyfence.core.configuration.SmartGpsConfig
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.Mockito
import org.mockito.invocation.InvocationOnMock
import org.mockito.stubbing.Answer
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.android.controller.ServiceController
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * The fused location API cancels a subscription by object identity: only the
 * exact [LocationCallback] instance handed to `requestLocationUpdates` can be
 * handed to `removeLocationUpdates` to stop it. A callback the tracker
 * registers but does not retain is therefore subscribed permanently — GPS keeps
 * waking the process for the life of that process, through `stopTracking()` and
 * past service destruction, with no handle left to cancel it.
 *
 * These cases pin the invariant that keeps the tracker cancellable: whatever
 * instance reaches `requestLocationUpdates` is the instance the tracker stores,
 * so a later stop names the same object. The reconfiguration path has a fallback
 * that constructs a callback when none is stored and discards it, which breaks
 * the invariant; the cases that clear the field first drive that fallback
 * directly, since the ordinary lifecycle assigns the field in `onCreate` and
 * never clears it.
 *
 * The registration and removal paths are private, and the fused client is an
 * interface the Service resolves in `onCreate`, so the cases drive the real
 * methods by reflection against a recording stand-in for that client. Recording
 * at the API boundary observes exactly which instances crossed it, which is the
 * only thing the identity contract turns on.
 */
@RunWith(RobolectricTestRunner::class)
class LocationCallbackRegistrationTest {

    private lateinit var tracker: LocationTracker

    /** Retained so a case can drive the Service through its real teardown. */
    private lateinit var controller: ServiceController<LocationTracker>

    /** Callback instances handed to the fused client, in call order. */
    private val registered = mutableListOf<LocationCallback>()

    /** Callback instances the tracker asked the fused client to cancel. */
    private val removed = mutableListOf<LocationCallback>()

    /**
     * Every subscription call in order, so a case can ask whether a callback
     * was left subscribed rather than only whether it was ever mentioned in a
     * removal. Re-registering an instance the tracker had already cancelled
     * re-opens it, which a set comparison would not catch.
     */
    private val subscriptionLog = mutableListOf<Pair<String, LocationCallback>>()

    @Before
    fun setUp() {
        registered.clear()
        removed.clear()
        subscriptionLog.clear()
        clearTrackingIntent()

        controller = Robolectric.buildService(LocationTracker::class.java).create()
        tracker = controller.get()
        setPrivateField("fusedLocationClient", recordingFusedClient())
    }

    @After
    fun tearDown() {
        if (::tracker.isInitialized) {
            LocationTracker.applyClearZonesDirect(tracker)
            tracker.onDestroy()
        }
        clearTrackingIntent()
    }

    // ---------------------------------------------------------------
    // Fixtures
    // ---------------------------------------------------------------

    /**
     * Records subscription traffic by intercepting every call rather than
     * stubbing named overloads: `requestLocationUpdates` is overloaded five
     * ways, and reading the callback out of the argument list keeps the
     * recorder indifferent to which overload production code picks.
     */
    private fun recordingFusedClient(): FusedLocationProviderClient {
        val recorder = Answer { invocation: InvocationOnMock ->
            val callback = invocation.arguments.filterIsInstance<LocationCallback>().firstOrNull()
            when (invocation.method.name) {
                "requestLocationUpdates" -> callback?.let {
                    registered.add(it)
                    subscriptionLog.add("register" to it)
                }
                "removeLocationUpdates" -> callback?.let {
                    removed.add(it)
                    subscriptionLog.add("remove" to it)
                }
                "toString" -> return@Answer "recordingFusedLocationClient"
            }
            null
        }
        return Mockito.mock(FusedLocationProviderClient::class.java, recorder)
    }

    /**
     * Callbacks whose most recent subscription call was a registration — the
     * ones still delivering location fixes.
     */
    private fun stillSubscribed(): List<LocationCallback> =
        registered.distinct().filter { callback ->
            subscriptionLog.last { it.second === callback }.first == "register"
        }

    private fun setPrivateField(name: String, value: Any?) {
        LocationTracker::class.java.getDeclaredField(name).apply {
            isAccessible = true
            set(tracker, value)
        }
    }

    private fun storedCallback(): LocationCallback? =
        LocationTracker::class.java.getDeclaredField("locationCallback").run {
            isAccessible = true
            get(tracker) as LocationCallback?
        }

    private fun invokePrivate(name: String) {
        LocationTracker::class.java.getDeclaredMethod(name).apply {
            isAccessible = true
            invoke(tracker)
        }
    }

    /** The initial subscription `startTracking` takes out once zones exist. */
    private fun startGpsUpdates() = invokePrivate("startGpsUpdates")

    /** The reconfiguration an accuracy-profile, activity or movement change runs. */
    private fun reconfigureGps() = invokePrivate("updateLocationRequest")

    private fun stopTracking() = invokePrivate("stopTracking")

    private fun clearTrackingIntent() {
        ApplicationProvider.getApplicationContext<Context>()
            .getSharedPreferences(LocationTracker.TRACKING_PREFS_NAME, Context.MODE_PRIVATE)
            .edit().clear().commit()
    }

    private fun grantLocationPermissions() {
        shadowOf(ApplicationProvider.getApplicationContext<Application>()).grantPermissions(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION,
            // The tracker's start gate additionally requires this from API 34,
            // and the reachability case pins that SDK deliberately.
            Manifest.permission.FOREGROUND_SERVICE_LOCATION
        )
    }

    private fun dispatch(action: String) {
        tracker.onStartCommand(Intent(action).setAction(action), 0, 1)
    }

    private fun circleZone(): Map<String, Any> = mapOf(
        "type" to "circle",
        "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
        "radius" to 100.0
    )

    // ---------------------------------------------------------------
    // Cases
    // ---------------------------------------------------------------

    /**
     * The reachability half of the question, driven through the consumer-facing
     * entry points rather than by reflection: start, reconfigure through the
     * companion the bridges call, stop. Every subscription this opens must be
     * closed by the time the service is stopped.
     */
    @Test
    @Config(sdk = [34])
    fun `a start reconfigure stop cycle over the real entry points cancels what it opened`() {
        grantLocationPermissions()

        dispatch(LocationTracker.ACTION_START_TRACKING)
        // GPS start is deferred until a zone exists, so the zone is what
        // actually opens the first subscription.
        LocationTracker.applyAddZoneDirect(tracker, "office", "Office", circleZone())
        LocationTracker.updateSmartConfiguration(SmartGpsConfig())

        dispatch(LocationTracker.ACTION_STOP_TRACKING)

        assertTrue("the cycle must have opened at least one subscription", registered.isNotEmpty())
        assertEquals(
            "callbacks still delivering fixes after the service stopped",
            emptyList<LocationCallback>(),
            stillSubscribed()
        )
    }

    @Test
    fun `a reconfiguration cancels and re-registers the callback the tracker holds`() {
        startGpsUpdates()
        val initial = storedCallback()
        assertNotNull("onCreate must leave a callback stored", initial)

        reconfigureGps()

        assertEquals(listOf(initial, initial), registered)
        assertEquals(listOf(initial), removed)
        assertSame(
            "the stored callback must still be the registered one after reconfiguring",
            initial,
            storedCallback()
        )
    }

    /**
     * Declining to register at all satisfies this too — the invariant is about
     * what happens when a registration does occur, not that one must.
     */
    /**
     * With no callback stored there is nothing that could later be cancelled,
     * so the method must do nothing at all rather than register a subscription
     * it cannot name. The fused client matches by identity: a handle the
     * tracker does not hold can never be passed to a removal, and would
     * outlive stopTracking() for the life of the process.
     */
    @Test
    fun `a reconfiguration with no callback stored registers nothing`() {
        setPrivateField("locationCallback", null)
        val before = registered.size

        reconfigureGps()

        assertEquals(
            "a subscription opened here could never be cancelled",
            before,
            registered.size
        )
    }

    @Test
    fun `a reconfiguration with no callback stored leaves nothing subscribed`() {
        setPrivateField("locationCallback", null)
        reconfigureGps()

        stopTracking()

        assertEquals(
            "GPS updates must not outlive stopTracking(): " +
                "registered=${registered.size}, removed=${removed.size}",
            emptyList<LocationCallback>(),
            stillSubscribed()
        )
    }

    /**
     * A Service can be destroyed without the consumer ever sending a stop —
     * a system stop, or a stopSelf from elsewhere. The subscription is held
     * by the fused client rather than by the Service, so it survives the
     * Service unless onDestroy cancels it, and a process that outlives the
     * Service goes on sampling GPS with nothing left to receive it.
     */
    @Test
    fun `destroying the service without a stop cancels its subscription`() {
        startGpsUpdates()
        assertTrue("expected a subscription to cancel", registered.isNotEmpty())

        controller.destroy()

        assertEquals(
            "GPS updates outlive the Service: " +
                "registered=${registered.size}, removed=${removed.size}",
            emptyList<LocationCallback>(),
            stillSubscribed()
        )
    }
}
