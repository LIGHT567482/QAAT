package ug.qaat.coordinator.ui

import ug.qaat.coordinator.db.OfficePersonEntity

/**
 * The OFFLINE office search, mirroring OfficeSearch on the server exactly.
 *
 * Extracted from the round screen for one reason: these two implementations diverging is a silent
 * failure. It does not throw and it does not log — it shows up only as a monitor standing at the
 * right door being told nobody by that name works here, and then either not filing the visit or
 * filing it against somebody else. So the rule lives in one function with a test on it rather than
 * inline in a composable nothing can exercise.
 *
 * THE RULE, and the SQL it mirrors:
 *
 *     AND ( btrim(lower(staff_id))                LIKE 'q%'     -- PREFIX
 *        OR btrim(lower(full_name))               LIKE '%q%'    -- CONTAINS
 *        OR btrim(lower(COALESCE(department,''))) LIKE '%q%'
 *        OR btrim(lower(COALESCE(office,'')))     LIKE '%q%' )
 *
 * PREFIX on the badge, because a monitor reads it off a card and types the start of it: "kiu/0"
 * must reach KIU/044. Deliberately NOT contains — "044" matching KIU/044 sounds helpful until a
 * three-digit fragment starts matching a third of the institution.
 *
 * CONTAINS on the name, department and office, because a registry name is "DR ANUMOLU SRINIVASA
 * RAO" and the nameplate on the door says ANUMOLU. Prefix-matching the name would return nothing
 * for the commonest thing a monitor types.
 */
internal object OfficeSearchMatch {

    fun matches(p: OfficePersonEntity, query: String): Boolean {
        val needle = query.trim().lowercase()
        // An empty query matches nobody, deliberately — the same rule the server applies, and the
        // same reason: a round that opens on everybody invites recording without visiting.
        if (needle.isEmpty()) return false

        return norm(p.staffId).startsWith(needle) ||
            norm(p.fullName).contains(needle) ||
            norm(p.department).contains(needle) ||
            norm(p.office).contains(needle)
    }

    fun filter(people: List<OfficePersonEntity>, query: String): List<OfficePersonEntity> =
        people.filter { matches(it, query) }.sortedBy { it.fullName.lowercase() }

    /** btrim(lower(COALESCE(x,''))) — the server normalises both sides, so this must too. */
    private fun norm(s: String?): String = (s ?: "").trim().lowercase()
}
