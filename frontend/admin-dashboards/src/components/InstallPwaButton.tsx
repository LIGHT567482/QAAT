import { useEffect, useState } from 'react'

// The browser's install prompt for the installed PWA. QAT's dashboards are already
// installable (manifest + icons + workbox in vite.config.ts) — this button is the one
// missing piece: an explicit "add to your home screen" affordance, which Chrome/Samsung
// Internet only reveal through `beforeinstallprompt`, and only while the site is
// installable. When the conditions are not met (already installed, iOS Safari) the
// button is simply not rendered.
interface BeforeInstallPromptEvent extends Event {
  prompt(): Promise<void>
  userChoice: Promise<{ outcome: 'accepted' | 'dismissed'; platform: string }>
}

export function InstallPwaButton({ style }: { style?: React.CSSProperties }) {
  const [prompt, setPrompt] = useState<BeforeInstallPromptEvent | null>(null)

  useEffect(() => {
    const onPrompt = (e: Event) => {
      e.preventDefault()
      setPrompt(e as BeforeInstallPromptEvent)
    }
    window.addEventListener('beforeinstallprompt', onPrompt)
    return () => window.removeEventListener('beforeinstallprompt', onPrompt)
  }, [])

  if (!prompt) return null

  return (
    <button
      onClick={async () => {
        await prompt.prompt()
        const choice = await prompt.userChoice
        if (choice.outcome === 'accepted') setPrompt(null)
      }}
      style={{
        width: '100%',
        padding: 9,
        background: 'transparent',
        color: 'var(--sidebar-text)',
        border: '1px solid rgba(255,255,255,.25)',
        borderRadius: 6,
        cursor: 'pointer',
        fontSize: 13,
        ...style,
      }}
    >
      Install app
    </button>
  )
}