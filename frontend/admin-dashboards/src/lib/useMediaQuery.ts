import { useEffect, useState } from 'react'

// Match a CSS media query from React, e.g. '(max-width: 959px)'. Used to collapse the
// fixed sidebar into a drawer on phones, so the dashboards are usable at any device
// size rather than shrinking a desktop column until it is unreadable.
export function useMediaQuery(query: string): boolean {
  const [matches, setMatches] = useState(() =>
    typeof window !== 'undefined' ? window.matchMedia(query).matches : false,
  )

  useEffect(() => {
    const mql = window.matchMedia(query)
    const onChange = (e: MediaQueryListEvent) => setMatches(e.matches)
    setMatches(mql.matches)
    mql.addEventListener('change', onChange)
    return () => mql.removeEventListener('change', onChange)
  }, [query])

  return matches
}