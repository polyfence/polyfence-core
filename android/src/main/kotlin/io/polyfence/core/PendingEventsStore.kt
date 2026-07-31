package io.polyfence.core

import android.content.Context
import android.util.Log
import java.io.BufferedWriter
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStreamWriter
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONObject

/**
 * Bounded append-only file store for zone-crossing events that need to survive
 * moments when the consumer's JS/Dart runtime is torn down but the polyfence-core
 * native service is still running.
 *
 * Off when queueSize is 0 (append is a no-op). Drain always reads whatever is on
 * disk regardless of the current queueSize, so events queued before the caller
 * disabled the feature stay retrievable — the underlying log file is preserved
 * across a queueSize=0 window and only cleared by an explicit drainAll.
 *
 * A dedicated single-thread executor serialises reads and writes; append and
 * drainAll are synchronous from the caller's perspective. drainAll dispatches
 * onto the same executor as append, so a concurrent append cannot lose an
 * event mid-drain.
 *
 * After shutdown, the underlying executor is stopped and further append /
 * drainAll calls silently fail (the executor rejects submissions); callers
 * must construct a new instance to resume. The on-disk log file is preserved
 * across shutdown so a new instance sees the same events.
 */
internal class PendingEventsStore(context: Context, private val queueSize: Int) {

    // Uses noBackupFilesDir so the queue is never included in Android Auto Backup
    // or Device-to-Device transfer — zone-crossing history must not leak to
    // Google Drive under a consumer app's backup policy. Same lifecycle as
    // filesDir otherwise: survives app updates, not wiped under memory pressure.
    private val storeDir = File(context.noBackupFilesDir, DIR_NAME).apply { mkdirs() }
    private val logFile = File(storeDir, LOG_FILE_NAME)
    private val countFile = File(storeDir, COUNT_FILE_NAME)
    private val writer = Executors.newSingleThreadExecutor { r ->
        Thread(r, "polyfence-pending-events")
    }
    private val droppedCount = AtomicLong(loadDroppedCount())

    // Starts true because this instance cannot know what a previous process
    // left on disk. Only ever cleared by observing an empty drain through this
    // instance, so a false reading is always something this store proved.
    @Volatile
    private var mayHaveQueuedEvents: Boolean = true

    /**
     * False only when this instance has already drained the log to empty and
     * nothing has been appended since. Lets a caller that fires on every
     * listener attach skip the file read in the overwhelmingly common
     * nothing-queued case; a true reading still requires a real drain to
     * confirm.
     */
    fun mayHaveEvents(): Boolean = mayHaveQueuedEvents

    /** Appends one event; returns the number of events evicted by this append. */
    fun append(event: Map<String, Any>): Int {
        if (queueSize <= 0) return 0
        val callable = java.util.concurrent.Callable {
            mayHaveQueuedEvents = true
            val existing = readAllUnsafe()
            existing.add(JSONObject(event))
            var evicted = 0
            while (existing.size > queueSize) {
                existing.removeAt(0)
                evicted++
            }
            writeAllUnsafe(existing)
            if (evicted > 0) {
                val newTotal = droppedCount.addAndGet(evicted.toLong())
                persistDroppedCountUnsafe(newTotal)
            }
            evicted
        }
        return try {
            writer.submit(callable).get()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to persist pending event: ${e.message}")
            0
        }
    }

    /** Reads every queued event and deletes them in a single serialised block. */
    fun drainAll(): List<Map<String, Any>> {
        val callable = java.util.concurrent.Callable {
            val events = readAllUnsafe()
            if (events.isNotEmpty()) {
                logFile.delete()
            }
            // Cleared on the writer thread so it is totally ordered against
            // append's own set — clearing it on the calling thread could
            // discard a flag raised by an append that queued behind this read.
            mayHaveQueuedEvents = false
            events.map { jsonToMap(it) }
        }
        return try {
            writer.submit(callable).get()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to drain pending events: ${e.message}")
            emptyList()
        }
    }

    /** Cumulative count of evicted events since first construction of a store on this device. */
    fun droppedCountValue(): Long = droppedCount.get()

    /**
     * Stops the internal writer thread. Blocks until any in-flight append or
     * drain completes (up to 1s) so a caller rebinding the store on a config
     * change has a happens-before against the outgoing writer — otherwise
     * `dropped_count` and `queue.jsonl` can race across the store swap and
     * lose events or regress the counter. Post-shutdown appends and drainAll
     * calls silently fail; callers must construct a new instance to resume.
     * The on-disk log file is preserved. Matches iOS `PendingEventsStore`'s
     * `serialQueue.sync {}` quiesce semantic.
     */
    fun shutdown() {
        writer.shutdown()
        try {
            writer.awaitTermination(1, TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    // The methods below run only inside the single-thread writer.

    private fun readAllUnsafe(): MutableList<JSONObject> {
        if (!logFile.exists()) return mutableListOf()
        val result = mutableListOf<JSONObject>()
        for (line in logFile.readLines()) {
            val trimmed = line.trim()
            if (trimmed.isEmpty()) continue
            val parsed = runCatching { JSONObject(trimmed) }.getOrNull()
            if (parsed != null) {
                result.add(parsed)
            } else {
                Log.w(TAG, "Skipping corrupted queue entry (${trimmed.length} chars)")
            }
        }
        return result
    }

    private fun writeAllUnsafe(events: List<JSONObject>) {
        val tmp = File(storeDir, TMP_FILE_NAME)
        // Force bytes to disk before rename. This is a queue for surviving
        // process death; the whole feature loses meaning if a power loss
        // between rename and disk-flush loses the last durable write. iOS's
        // `Data.write(to:options:.atomic)` performs the same fsync-then-
        // rename dance; matching it on Android needs an explicit fd.sync
        // because `File.bufferedWriter()` only flushes to the buffer, not to
        // the storage device.
        FileOutputStream(tmp).use { fos ->
            val writer = BufferedWriter(OutputStreamWriter(fos, Charsets.UTF_8))
            events.forEach {
                writer.write(it.toString())
                writer.newLine()
            }
            writer.flush()
            fos.fd.sync()
        }
        if (!tmp.renameTo(logFile)) {
            logFile.delete()
            tmp.renameTo(logFile)
        }
    }

    private fun loadDroppedCount(): Long {
        return runCatching { countFile.readText().trim().toLong() }.getOrDefault(0L)
    }

    private fun persistDroppedCountUnsafe(value: Long) {
        val tmp = File(storeDir, TMP_COUNT_FILE_NAME)
        // Same fsync-before-rename discipline as writeAllUnsafe — a stale
        // droppedCount that survives a crash after the queue.jsonl was
        // rewritten would silently under-count evictions when the app
        // recovers.
        FileOutputStream(tmp).use { fos ->
            fos.write(value.toString().toByteArray(Charsets.UTF_8))
            fos.fd.sync()
        }
        if (!tmp.renameTo(countFile)) {
            countFile.delete()
            tmp.renameTo(countFile)
        }
    }

    private fun jsonToMap(o: JSONObject): Map<String, Any> {
        val m = mutableMapOf<String, Any>()
        o.keys().forEach { k -> o.opt(k)?.let { v -> m[k] = v } }
        return m
    }

    companion object {
        private const val TAG = "PendingEventsStore"
        private const val DIR_NAME = "pending_events"
        private const val LOG_FILE_NAME = "queue.jsonl"
        private const val TMP_FILE_NAME = "queue.jsonl.tmp"
        private const val COUNT_FILE_NAME = "dropped_count"
        private const val TMP_COUNT_FILE_NAME = "dropped_count.tmp"
    }
}
