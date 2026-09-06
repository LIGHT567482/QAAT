import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import ug.qaat.coordinator.db.OfficePersonEntity
import ug.qaat.coordinator.ui.OfficeSearchMatch

/**
 * The offline office search must give the SAME answer as the server.
 *
 * A monitor's phone falls back to this whenever there is no signal, which in a concrete building is
 * most of a round. If the two rules diverge, nothing throws and nothing logs: the monitor standing
 * at the right door is simply told nobody by that name works here, and then either files nothing or
 * files the visit against somebody else.
 *
 * Each case below quotes the SQL predicate it mirrors, from OfficeSearch in
 * backend/api-gateway/internal/handlers/employee_patrol.go:
 *
 *     AND ( btrim(lower(staff_id))                LIKE 'q%'
 *        OR btrim(lower(full_name))               LIKE '%q%'
 *        OR btrim(lower(COALESCE(department,''))) LIKE '%q%'
 *        OR btrim(lower(COALESCE(office,'')))     LIKE '%q%' )
 */
class OfficeSearchMatchTest {

    private val rao = OfficePersonEntity(
        staffId = "KIU/044", fullName = "DR ANUMOLU SRINIVASA RAO",
        department = "Finance", jobTitle = "Bursar", office = "Block C, Room 14",
    )
    private val auma = OfficePersonEntity(
        staffId = "KIU/112", fullName = "C. Auma",
        department = "Library", jobTitle = "Librarian", office = "Library office",
    )

    // ── full_name LIKE '%q%' — CONTAINS ─────────────────────────────────────────

    @Test
    fun `a surname in the middle of a registry name matches`() {
        // The case prefix-matching would have broken. The registry holds the full formal name;
        // the nameplate on the door says ANUMOLU, and that is what the monitor types.
        assertTrue(OfficeSearchMatch.matches(rao, "anumolu"))
        assertTrue(OfficeSearchMatch.matches(rao, "srinivasa"))
        assertTrue(OfficeSearchMatch.matches(rao, "rao"))
    }

    @Test
    fun `name matching ignores case and surrounding whitespace`() {
        // btrim(lower(...)) on both sides.
        assertTrue(OfficeSearchMatch.matches(rao, "  AnUmOlU  "))
    }

    // ── staff_id LIKE 'q%' — PREFIX, deliberately not contains ──────────────────

    @Test
    fun `a badge prefix matches`() {
        assertTrue(OfficeSearchMatch.matches(rao, "kiu/0"))
        assertTrue(OfficeSearchMatch.matches(rao, "KIU/044"))
    }

    @Test
    fun `a badge fragment does not match`() {
        // "044" finding KIU/044 sounds helpful until a three-digit fragment starts matching a
        // third of the institution. The server is prefix-only, so this must be too — an offline
        // hit the server would not have returned is just as wrong as a miss.
        assertFalse(OfficeSearchMatch.matches(rao, "044"))
        assertFalse(OfficeSearchMatch.matches(rao, "/044"))
    }

    // ── department and office LIKE '%q%' ────────────────────────────────────────

    @Test
    fun `department matches on contains`() {
        assertTrue(OfficeSearchMatch.matches(rao, "finance"))
        assertTrue(OfficeSearchMatch.matches(auma, "libr"))
    }

    @Test
    fun `office matches on contains`() {
        // How a monitor works a corridor: they type the block they are standing in.
        assertTrue(OfficeSearchMatch.matches(rao, "block c"))
        assertTrue(OfficeSearchMatch.matches(rao, "room 14"))
    }

    // ── the empty query ─────────────────────────────────────────────────────────

    @Test
    fun `a blank query matches nobody`() {
        // The server returns an empty result for a blank q rather than everybody, because a round
        // that opens on the whole institution invites recording without visiting.
        assertFalse(OfficeSearchMatch.matches(rao, ""))
        assertFalse(OfficeSearchMatch.matches(rao, "   "))
        assertTrue(OfficeSearchMatch.filter(listOf(rao, auma), "  ").isEmpty())
    }

    @Test
    fun `no match is no match`() {
        assertFalse(OfficeSearchMatch.matches(rao, "zzz"))
        assertFalse(OfficeSearchMatch.matches(auma, "finance"))
    }

    // ── the list ────────────────────────────────────────────────────────────────

    @Test
    fun `filter returns the matches ordered by name, as the server orders them`() {
        val zeta = rao.copy(staffId = "KIU/900", fullName = "Zeta Nabbosa", department = "Finance")
        val alpha = rao.copy(staffId = "KIU/901", fullName = "Alpha Kato", department = "Finance")
        val got = OfficeSearchMatch.filter(listOf(zeta, alpha, auma), "finance")
        assertEquals(listOf("Alpha Kato", "Zeta Nabbosa"), got.map { it.fullName })
    }

    @Test
    fun `a person with no office or department is still findable by name`() {
        // Two of the four ingestion paths create employees with no department at all (the tablet
        // stub and the U-Panel punch), so blank columns are the normal case, not the edge one.
        val bare = OfficePersonEntity(staffId = "KIU/777", fullName = "B. Mugisha")
        assertTrue(OfficeSearchMatch.matches(bare, "mugisha"))
        assertTrue(OfficeSearchMatch.matches(bare, "kiu/7"))
        assertFalse(OfficeSearchMatch.matches(bare, "finance"))
    }
}
