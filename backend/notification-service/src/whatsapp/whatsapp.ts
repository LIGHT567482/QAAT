// Pluggable WhatsApp sender. It is a no-op that just logs until you provide provider
// credentials via environment variables — so the notification flow works end-to-end now
// (email + app) and WhatsApp "lights up" the moment creds are set, with no code change.
//
// The SENDER number is configurable and defaults to 0786713144 (the QA business number),
// not hard-coded. Change it in the service environment (WHATSAPP_FROM_NUMBER) the day the
// institution assigns a different number — no redeploy. The number must still be the one
// registered with the chosen provider.
//
//   Sender: WHATSAPP_FROM_NUMBER   (defaults to +256786713144; local "0786…" is accepted)
//   Twilio: WHATSAPP_PROVIDER=twilio, TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN
//   Meta:   WHATSAPP_PROVIDER=meta, META_PHONE_NUMBER_ID, META_ACCESS_TOKEN

export interface WhatsAppConfig {
  provider: string
  from: string
  configured: boolean
  hint: string
}

// Raw sender as given by env, defaulting to the QA business number 0786713144.
function fromRaw(): string {
  return (process.env.WHATSAPP_FROM_NUMBER ?? '+256786713144').trim()
}

// toE164 normalises a Ugandan mobile written in local style ("0786713144") to full
// international form ("+256786713144"). Numbers already in E.164 are left alone; anything
// else passes through digit-scrubbed but structurally unmodified. The country code applied
// to a local-form number is the one the configured sender sits in, so a future sender from
// another country keeps working.
function toE164(raw: string): string {
  const s = (raw ?? '').trim().replace(/[^\d+]/g, '')
  if (!s) return ''
  if (s.startsWith('+')) return s
  const sender = toE164From()
  if (sender.startsWith('+256') && /^0\d{9}$/.test(s)) return '+256' + s.slice(1)
  if (sender.startsWith('+256') && /^\d{9}$/.test(s)) return '+256' + s
  return s
}

function toE164From(): string {
  const r = fromRaw()
  const digits = r.replace(/[^\d+]/g, '')
  if (digits.startsWith('+')) return digits
  if (/^0\d{9}$/.test(digits)) return '+256' + digits.slice(1)
  if (/^\d{9}$/.test(digits)) return '+256' + digits
  return digits
}

export function getWhatsAppConfig(): WhatsAppConfig {
  const provider = (process.env.WHATSAPP_PROVIDER ?? '').toLowerCase()
  const from = toE164From()
  let configured = false
  let hint = ''
  if (provider === 'twilio') {
    configured = Boolean(process.env.TWILIO_ACCOUNT_SID && process.env.TWILIO_AUTH_TOKEN)
    hint = configured
      ? ''
      : 'TWILIO_ACCOUNT_SID and TWILIO_AUTH_TOKEN are required.'
  } else if (provider === 'meta') {
    configured = Boolean(process.env.META_ACCESS_TOKEN && process.env.META_PHONE_NUMBER_ID)
    hint = configured
      ? ''
      : 'META_PHONE_NUMBER_ID and META_ACCESS_TOKEN are required.'
  } else {
    hint = `set WHATSAPP_PROVIDER to 'twilio' or 'meta' and that provider's credentials.`
  }
  return { provider, from, configured, hint }
}

export async function sendWhatsApp(toPhone: string, message: string): Promise<boolean> {
  const provider = (process.env.WHATSAPP_PROVIDER ?? '').toLowerCase()
  const phone = toE164(toPhone)
  if (!phone) return false
  const { from } = getWhatsAppConfig()
  try {
    if (provider === 'twilio' && process.env.TWILIO_ACCOUNT_SID) {
      const sid = process.env.TWILIO_ACCOUNT_SID
      const token = process.env.TWILIO_AUTH_TOKEN ?? ''
      const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
        method: 'POST',
        headers: {
          Authorization: 'Basic ' + Buffer.from(`${sid}:${token}`).toString('base64'),
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: new URLSearchParams({ From: `whatsapp:${from}`, To: `whatsapp:${phone}`, Body: message }),
      })
      if (!res.ok) console.warn(`[whatsapp] twilio rejected to=${phone} from=${from}: HTTP ${res.status} ${await res.text()}`)
      return res.ok
    }
    if (provider === 'meta' && process.env.META_ACCESS_TOKEN) {
      const pnid = process.env.META_PHONE_NUMBER_ID
      const token = process.env.META_ACCESS_TOKEN
      const res = await fetch(`https://graph.facebook.com/v20.0/${pnid}/messages`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          messaging_product: 'whatsapp',
          to: phone.replace('+', ''),
          type: 'text',
          text: { body: message },
        }),
      })
      if (!res.ok) console.warn(`[whatsapp] meta rejected to=${phone} from=${from}: HTTP ${res.status} ${await res.text()}`)
      return res.ok
    }
  } catch (e) {
    console.warn(`[whatsapp] send failed to=${phone} from=${from}`, e)
    return false
  }
  // Not configured (or unknown provider) — LOG LOUDLY so it cannot look like delivery.
  // The sender number is named, and the message is credited to the number it would have
  // come from, so an operator reading the log sees exactly what is (not) happening.
  console.warn(
    `[whatsapp:stub] NOT CONFIGURED — no message was sent to=${phone} from=${from}. ` +
      `The alert would have come from ${from}. Sender is changeable via WHATSAPP_FROM_NUMBER. ` +
      getWhatsAppConfig().hint
  )
  return false
}
