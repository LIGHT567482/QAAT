package ug.qaat.coordinator.session

import ug.qaat.coordinator.db.TimetableSlotEntity

/**
 * WHICH OF TODAY'S SITTINGS OF A UNIT IS THE ONE HAPPENING NOW.
 *
 * A unit can be timetabled more than once on the same day — the same module to a Day cohort at
 * 08:00 and a Weekend cohort at 14:00 — so "today's slot for this unit" is not a single row and
 * picking the first would attach a lecture to the wrong sitting half the time.
 *
 * This lived in SessionController, which ran the hotspot and has been deleted with it. The function
 * itself has nothing to do with hotspots: it is pure timetable arithmetic, it is what the
 * combined-class code is derived from, and it is covered by its own tests. Moving it here keeps it
 * rather than losing a working, tested piece of logic to an unrelated removal.
 */
private fun minutesOfDay(hhmm: String): Int {
    val parts = hhmm.trim().split(":")
    if (parts.size < 2) return -1
    val h = parts[0].toIntOrNull() ?: return -1
    val m = parts[1].toIntOrNull() ?: return -1
    if (h !in 0..23 || m !in 0..59) return -1
    return h * 60 + m
}

/**
 * The slot [unitId] is being taught in RIGHT NOW, out of the cached weekly grid.
 *
 * It matters which one: the combined-class code is derived from the slot's room, day and hour, so a
 * unit taught twice on one day derives two different codes, and handing back the wrong slot would
 * produce three digits that open nobody's register. Picking the earliest slot of the day — which is
 * what the manifest's own per-unit list does — would be wrong every afternoon.
 *
 * So: the slot actually in progress, else the next one still to come today, else the day's last.
 * The fallbacks exist because a coordinator opens the session a few minutes early as often as a few
 * minutes late, and neither should silently derive a code from the wrong hour.
 *
 * Pure and top-level so it can be tested without a device — see CombinedClassWiringTest.
 */
fun slotForToday(
    slots: List<TimetableSlotEntity>,
    unitId: String,
    isoDay: Int,
    nowMinutes: Int,
): TimetableSlotEntity? {
    val today = slots.filter { it.unitId == unitId && it.dayOfWeek == isoDay && minutesOfDay(it.startTime) >= 0 }
    if (today.size <= 1) return today.firstOrNull()
    today.firstOrNull {
        val start = minutesOfDay(it.startTime)
        nowMinutes >= start && nowMinutes < start + maxOf(it.durationMinutes, 1)
    }?.let { return it }
    today.filter { minutesOfDay(it.startTime) >= nowMinutes }
        .minByOrNull { minutesOfDay(it.startTime) }
        ?.let { return it }
    return today.maxByOrNull { minutesOfDay(it.startTime) }
}
