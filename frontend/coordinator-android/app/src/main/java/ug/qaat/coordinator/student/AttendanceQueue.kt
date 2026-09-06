package ug.qaat.coordinator.student

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * THE CHECK-IN THAT COULD NOT BE SENT, KEPT UNTIL IT CAN BE.
 *
 * The hotspot is gone. It answered the no-signal problem by not needing a network — the
 * coordinator's phone was the server — and without it a hall with no coverage has no way to record
 * anybody at the moment it happens. So the app tries the gateway first, and when it cannot reach
 * it the check-in is written here and uploaded when a connection returns.
 *
 * WRITTEN BEFORE THE ATTEMPT, NOT AFTER IT FAILS. A student taps once, in a corridor, and walks
 * away; if the queue were only written in the failure branch then a process death mid-request would
 * lose the tap entirely and the student would be absent for a lecture they attended. So the item is
 * persisted first and removed only once the server has confirmed it — the same order a durable
 * queue is always written in, for the same reason.
 *
 * Each item carries its own id. That id is what lets the server recognise the same tap arriving
 * twice after a flaky upload and count it once, so retrying is always safe: the worst case of a
 * duplicate send is a DUPLICATE response, never a second attendance.
 *
 * The coordinates and the time are captured HERE, when the student taps — not when the upload
 * happens. A queue drained at midnight from a lecture at noon must present where the student was
 * at noon, or the geofence would be judged against a bedroom.
 */
class AttendanceQueue(context: Context) {
    private val prefs = context.getSharedPreferences("qaat_attendance_queue", Context.MODE_PRIVATE)

    data class Item(
        val queueId: String,
        val sessionCode: String,
        val studentId: String,
        val latitude: Double?,
        val longitude: Double?,
        val deviceId: String,
        val capturedAt: String,
    )

    /** Persist a tap. Returns the queue id, which is also what makes the upload idempotent. */
    fun enqueue(
        sessionCode: String, studentId: String,
        latitude: Double?, longitude: Double?, deviceId: String, capturedAt: String,
    ): String {
        val id = UUID.randomUUID().toString()
        val arr = load()
        arr.put(JSONObject().apply {
            put("queue_id", id)
            put("session_code", sessionCode)
            put("student_id", studentId)
            if (latitude != null) put("latitude", latitude)
            if (longitude != null) put("longitude", longitude)
            put("device_id", deviceId)
            put("captured_at", capturedAt)
        })
        save(arr)
        return id
    }

    fun pending(): List<Item> {
        val arr = load()
        val out = ArrayList<Item>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            out.add(
                Item(
                    queueId = o.optString("queue_id"),
                    sessionCode = o.optString("session_code"),
                    studentId = o.optString("student_id"),
                    latitude = if (o.has("latitude")) o.optDouble("latitude") else null,
                    longitude = if (o.has("longitude")) o.optDouble("longitude") else null,
                    deviceId = o.optString("device_id"),
                    capturedAt = o.optString("captured_at"),
                )
            )
        }
        return out
    }

    fun size(): Int = load().length()

    /**
     * Drop the items the server has accounted for.
     *
     * STORED and DUPLICATE both count as settled. A duplicate means the record is already there —
     * usually this exact item uploaded before and the response was lost — so keeping it would make
     * the phone retry something that can never change, forever.
     *
     * A REJECTED item is also removed. That is deliberate and worth stating: a check-in refused for
     * being outside the geofence, or for a code that never existed, will be refused identically on
     * every future attempt, and a queue that never drains is one that blocks every later check-in
     * behind it. The rejection is not lost — the server records every attempt with its reason, so
     * the student's failed attempt is on the record even though the phone stops asking.
     */
    fun settle(queueIds: Collection<String>) {
        if (queueIds.isEmpty()) return
        val keep = JSONArray()
        val done = queueIds.toHashSet()
        val arr = load()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            if (!done.contains(o.optString("queue_id"))) keep.put(o)
        }
        save(keep)
    }

    fun clear() = save(JSONArray())

    private fun load(): JSONArray =
        runCatching { JSONArray(prefs.getString(KEY, "[]")) }.getOrElse { JSONArray() }

    private fun save(arr: JSONArray) = prefs.edit().putString(KEY, arr.toString()).apply()

    private companion object { const val KEY = "items" }
}
