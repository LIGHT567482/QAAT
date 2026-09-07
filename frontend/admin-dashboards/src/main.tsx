import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import brand from './brand.json'
import { startKeepWarm } from './lib/keepWarm'
import { applyPalette } from './theme'

// Instant institution branding from the bundled brand.json (single source of truth), applied
// before render so even the login page is on-brand; the backend branding fetch later confirms it.
applyPalette(brand)

// Keep the free-tier backend instances awake while this app is open on any device (see
// lib/keepWarm.ts). Started before render so the first health ping fires immediately.
startKeepWarm()

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
