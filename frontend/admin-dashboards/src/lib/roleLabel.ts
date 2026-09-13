/**
 * What each role is CALLED, as distinct from what it is stored as.
 *
 * The QA officer, patroller and school-handler roles were merged into a single `QA_MONITOR`
 * (migration 110). Accounts now store and are issued that one value; the legacy labels below are
 * kept only so a stale session persisted under an old token still renders a name instead of a raw
 * enum.
 *
 * Anything not listed falls back to the underscore-free form, which is right for ADMIN, VC, DEAN
 * and the rest.
 */
const LABELS: Record<string, string> = {
  QA_MONITOR:        'QA Monitor',
  QA_PATROLLER:      'QA Monitor',
  QA_OFFICER:        'QA Monitor',
  QA_SCHOOL_HANDLER: 'QA Monitor',
  QA_DEPT_REP:       'QA Dept Rep',
  DQA_DIRECTOR:      'DQA Director',
  HOD:               'Head of Department',
  TLC:               'Teaching & Learning Centre',
}

/** Title-case display name for a role, e.g. "QA Monitor". */
export function roleLabel(role: string): string {
  return LABELS[role] ?? role.replace(/_/g, ' ')
}

/** Lower-case, for the middle of a sentence: "a department is required for a qa monitor". */
export function roleLabelLower(role: string): string {
  return roleLabel(role).toLowerCase()
}
