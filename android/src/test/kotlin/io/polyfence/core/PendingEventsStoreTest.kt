package io.polyfence.core

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

@RunWith(RobolectricTestRunner::class)
class PendingEventsStoreTest {

    private lateinit var context: Context
    private lateinit var storeDir: File

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        storeDir = File(context.noBackupFilesDir, "pending_events")
        storeDir.deleteRecursively()
    }

    @After
    fun tearDown() {
        storeDir.deleteRecursively()
    }

    @Test
    fun `zero size disables persistence — append is a no-op`() {
        val store = PendingEventsStore(context, queueSize = 0)
        val evicted = store.append(mapOf("zoneId" to "z1", "eventType" to "ENTER"))
        assertEquals(0, evicted)
        assertTrue(store.drainAll().isEmpty())
    }

    @Test
    fun `drain returns events oldest-first and clears the log`() {
        val store = PendingEventsStore(context, queueSize = 10)
        store.append(mapOf("zoneId" to "z1", "eventType" to "ENTER", "seq" to 1))
        store.append(mapOf("zoneId" to "z2", "eventType" to "EXIT", "seq" to 2))
        store.append(mapOf("zoneId" to "z3", "eventType" to "ENTER", "seq" to 3))
        val drained = store.drainAll()
        assertEquals(3, drained.size)
        assertEquals(1, (drained[0]["seq"] as Number).toInt())
        assertEquals(3, (drained[2]["seq"] as Number).toInt())
        assertTrue(store.drainAll().isEmpty())
    }

    @Test
    fun `eviction drops oldest events and increments the counter`() {
        val store = PendingEventsStore(context, queueSize = 2)
        assertEquals(0, store.append(mapOf("seq" to 1)))
        assertEquals(0, store.append(mapOf("seq" to 2)))
        assertEquals(1, store.append(mapOf("seq" to 3)))
        assertEquals(1, store.append(mapOf("seq" to 4)))
        assertEquals(2L, store.droppedCountValue())
        val drained = store.drainAll()
        assertEquals(2, drained.size)
        assertEquals(3, (drained[0]["seq"] as Number).toInt())
        assertEquals(4, (drained[1]["seq"] as Number).toInt())
    }

    @Test
    fun `drop counter survives across instances`() {
        val a = PendingEventsStore(context, queueSize = 1)
        a.append(mapOf("seq" to 1))
        a.append(mapOf("seq" to 2))
        assertEquals(1L, a.droppedCountValue())
        val b = PendingEventsStore(context, queueSize = 1)
        assertEquals(1L, b.droppedCountValue())
    }

    @Test
    fun `pending events survive across instances (process-death sim)`() {
        val a = PendingEventsStore(context, queueSize = 10)
        a.append(mapOf("zoneId" to "z1", "eventType" to "ENTER"))
        a.append(mapOf("zoneId" to "z1", "eventType" to "EXIT"))
        val b = PendingEventsStore(context, queueSize = 10)
        val drained = b.drainAll()
        assertEquals(2, drained.size)
        assertEquals("ENTER", drained[0]["eventType"])
        assertEquals("EXIT", drained[1]["eventType"])
    }

    @Test
    fun `first append on fresh install actually persists`() {
        val store = PendingEventsStore(context, queueSize = 10)
        val evicted = store.append(mapOf("zoneId" to "z1", "eventType" to "ENTER"))
        assertEquals(0, evicted)
        val readback = PendingEventsStore(context, queueSize = 10)
        val drained = readback.drainAll()
        assertEquals(1, drained.size)
        assertEquals("ENTER", drained[0]["eventType"])
    }

    @Test
    fun `queueSize of one keeps only the newest event`() {
        val store = PendingEventsStore(context, queueSize = 1)
        assertEquals(0, store.append(mapOf("seq" to 1)))
        assertEquals(1, store.append(mapOf("seq" to 2)))
        assertEquals(1, store.append(mapOf("seq" to 3)))
        val drained = store.drainAll()
        assertEquals(1, drained.size)
        assertEquals(3, (drained[0]["seq"] as Number).toInt())
        assertEquals(2L, store.droppedCountValue())
    }

    @Test
    fun `drainAll returns events even after queue is disabled`() {
        val enabled = PendingEventsStore(context, queueSize = 5)
        enabled.append(mapOf("seq" to 1))
        enabled.append(mapOf("seq" to 2))
        val disabled = PendingEventsStore(context, queueSize = 0)
        val drained = disabled.drainAll()
        assertEquals(2, drained.size)
    }

    @Test
    fun `concurrent appends from multiple threads serialise via the executor`() {
        val store = PendingEventsStore(context, queueSize = 100)
        val threadCount = 8
        val perThread = 10
        val threads = (0 until threadCount).map { tId ->
            Thread {
                for (i in 0 until perThread) {
                    store.append(mapOf("thread" to tId, "seq" to i))
                }
            }
        }
        threads.forEach { it.start() }
        threads.forEach { it.join() }
        val drained = store.drainAll()
        assertEquals(threadCount * perThread, drained.size)
    }

    @Test
    fun `corrupt line in the log is skipped on drain`() {
        storeDir.mkdirs()
        File(storeDir, "queue.jsonl").writeText(
            """
            {"zoneId":"a","eventType":"ENTER"}
            NOT_JSON_AT_ALL
            {"zoneId":"b","eventType":"EXIT"}
            """.trimIndent()
        )
        val store = PendingEventsStore(context, queueSize = 10)
        val drained = store.drainAll()
        assertEquals(2, drained.size)
        assertEquals("a", drained[0]["zoneId"])
        assertEquals("b", drained[1]["zoneId"])
    }

    @Test
    fun `corrupt dropped_count file is treated as zero`() {
        storeDir.mkdirs()
        File(storeDir, "dropped_count").writeText("not-a-number")
        val store = PendingEventsStore(context, queueSize = 5)
        assertEquals(0L, store.droppedCountValue())
    }

    @Test
    fun `shutdown releases the executor and the file survives`() {
        val store = PendingEventsStore(context, queueSize = 5)
        store.append(mapOf("seq" to 1))
        store.shutdown()
        val readback = PendingEventsStore(context, queueSize = 5)
        val drained = readback.drainAll()
        assertEquals(1, drained.size)
    }
}
