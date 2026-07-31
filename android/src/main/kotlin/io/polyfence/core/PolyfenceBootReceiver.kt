package io.polyfence.core

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.util.Log

/**
 * Re-registers OS wake fences after a device restart.
 *
 * Google Play Services drops every registered geofence on reboot, so without
 * this a phone that restarts overnight would have no wake coverage until the
 * user next opened the app — which is precisely the long-idle window the
 * feature exists to cover. iOS needs no equivalent: `CLCircularRegion`
 * monitoring is restored by the system across reboots, and the app is relaunched
 * in the background on a crossing.
 *
 * Gated twice so a consumer with the feature off pays nothing: the component is
 * declared disabled and only enabled while `osGeofenceWakeEnabled` is on (see
 * [setEnabled]), and the system delivers the broadcast only to apps that declare
 * `RECEIVE_BOOT_COMPLETED`. polyfence-core deliberately does not declare that
 * permission on the consumer's behalf — see the Android integration notes in
 * the README.
 *
 * Even once invoked, a no-op unless OS wake fences were enabled at last
 * shutdown and at least one zone is persisted.
 */
class PolyfenceBootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in BOOT_ACTIONS) return

        val appContext = context.applicationContext

        // Loading persisted zones and talking to Play Services is disk plus IPC,
        // and onReceive runs on the main thread of a process the system has just
        // cold-started. goAsync keeps the process alive while a worker does it.
        val pendingResult = goAsync()
        Thread {
            try {
                val registered = OsGeofenceRegistrar.registerFromPersistedZones(appContext)
                if (registered > 0) {
                    Log.i(TAG, "Re-registered $registered OS wake fences after boot")
                }
            } catch (e: Throwable) {
                // Throwable, not Exception: on a device without Play Services
                // the geofencing classes raise NoClassDefFoundError, which an
                // Exception catch would let escape on this bare thread and
                // crash the consumer's app the moment the user powers on.
                Log.w(TAG, "Failed to re-register OS wake fences after boot: ${e.message}")
            } finally {
                pendingResult.finish()
            }
        }.start()
    }

    companion object {
        private const val TAG = "PolyfenceBootReceiver"

        /**
         * Enables or disables the manifest component. Declared disabled so a
         * consumer with OS wake fences off never has its process cold-started
         * at boot; flipped on when the feature is enabled and off again when it
         * is turned back off. The setting survives reboots, which is what makes
         * it usable as the boot gate.
         */
        internal fun setEnabled(context: Context, enabled: Boolean) {
            val target = if (enabled) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } else {
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            }
            try {
                val component = ComponentName(
                    context.applicationContext,
                    PolyfenceBootReceiver::class.java
                )
                val pm = context.applicationContext.packageManager
                if (pm.getComponentEnabledSetting(component) == target) return
                pm.setComponentEnabledSetting(component, target, PackageManager.DONT_KILL_APP)
            } catch (e: Exception) {
                Log.w(TAG, "Could not update boot-receiver component state: ${e.message}")
            }
        }

        /**
         * Several OEM ROMs (Xiaomi, HTC) deliver a proprietary quick-boot
         * action instead of BOOT_COMPLETED when the device resumes from their
         * fast-boot state, and never send the standard one.
         */
        private val BOOT_ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON"
        )
    }
}
