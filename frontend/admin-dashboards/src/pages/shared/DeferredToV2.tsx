/**
 * WHAT A PAGE SHOULD SAY WHEN THE THING IT DID IS NOT IN THIS VERSION.
 *
 * v1 of KIU QAAT ships as an INTERNAL Quality Assurance system: lecturer attendance, employee
 * attendance, the QA monitor round, the timetable and the reports drawn from them. Two modules
 * are deferred to v2 — everything to do with STUDENTS, and the U-PANEL integration.
 *
 * The screens for those modules could have been deleted, or left in place to fail against routes
 * that no longer answer. Both are worse than saying so. A deleted page gives whoever bookmarked it
 * a 404 that reads as a broken deployment; a live form posting into a void wastes somebody's
 * afternoon and then loses their work.
 *
 * So the routes survive and answer plainly. The pages themselves are untouched in the repository
 * and the handlers behind them still compile, so restoring is uncommenting rather than rewriting.
 */
export default function DeferredToV2({ module = 'student' }: { module?: 'student' | 'upanel' }) {
  const copy = module === 'upanel' ? UPANEL : STUDENT
  return (
    <div style={{ maxWidth: 620 }}>
      <h2 style={{ margin: '0 0 6px' }}>{copy.title}</h2>
      {copy.body.map((line, i) => (
        <p key={i} style={{ color: 'var(--muted)', lineHeight: 1.6 }}>{line}</p>
      ))}
      <p style={{ color: 'var(--muted)', lineHeight: 1.6 }}>
        Nothing already recorded has been removed. This module is planned for version 2.
      </p>
    </div>
  )
}

const STUDENT = {
  title: 'The student module is not in this version',
  body: [
    'Student records, student attendance and everything that recorded or reported them are turned '
    + 'off in v1 — the student app, the check-in endpoints, the student registers and the '
    + 'eligibility and at-risk reports drawn from them.',
    'The QA monitor round is unaffected: monitors record taught / not-taught exactly as before, and '
    + 'coverage reporting is unchanged. Lecturer attendance, employee attendance, presence disputes '
    + 'and the timetable are also untouched.',
  ],
}

const UPANEL = {
  title: 'The U-Panel integration is not in this version',
  body: [
    'v1 runs self-contained: QAAT makes no call out to U-Panel and shows no U-Panel-sourced row. '
    + 'Every figure on the dashboards is measured from what this system recorded itself.',
    'Lecturer and employee attendance still report in full from QAAT’s own gate scans, monitor '
    + 'rounds and employee sheets.',
  ],
}
