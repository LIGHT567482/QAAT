import express from 'express'
import nodemailer from 'nodemailer'
import { syncOverdueEmail, qrReissuedEmail, wardenDataReceivedEmail } from './email/templates.js'
import { sendSyncOverduePush, sendWardenDataPush } from './push/web-push.js'
import { sendWhatsApp, getWhatsAppConfig } from './whatsapp/whatsapp.js'

const app = express()
app.use(express.json())

const transporter = nodemailer.createTransport({
  host:   process.env.SMTP_HOST ?? 'mailhog',
  port:   Number(process.env.SMTP_PORT ?? 1025),
  secure: process.env.SMTP_SECURE === 'true',
  auth:   process.env.SMTP_USER
    ? { user: process.env.SMTP_USER, pass: process.env.SMTP_PASS }
    : undefined,
})

// sender address on EVERY outgoing email. First EMAIL_FROM (the knob ops sets in Render
// to match the domain their SMTP relay is authorised for — SPF/DKIM bind the envelope to
// it), then the tenant branding domain when it is a real domain, then qaat.local. Under a
// mailhog dev host qaat.local never leaves the machine; in production SMTP_HOST is real
// and EMAIL_FROM decides what the recipient sees.
function fromAddress(domain?: string): string {
  const envFrom = process.env.EMAIL_FROM?.trim()
  if (envFrom) return envFrom
  const d = (domain ?? '').trim().toLowerCase()
  if (d.includes('.') && !d.includes('@')) return `noreply@${d}`
  return 'noreply@qaat.local'
}

// Machine-readable mail configuration for /health and /notify/test-send. "configured" is
// deliberately crude: local dev uses mailhog (host name 'mailhog' / ':1025') and nothing
// is configured; production sets a real SMTP_HOST, usually with a USER. Anything that is
// not mailhog counts as configured, because a deployment that claims to send mail must at
// least name a relay.
function emailConfig() {
  const host = (process.env.SMTP_HOST ?? 'mailhog').trim()
  return {
    host,
    port: Number(process.env.SMTP_PORT ?? 1025),
    secure: process.env.SMTP_SECURE === 'true',
    userSet: Boolean(process.env.SMTP_USER),
    configured: host.toLowerCase() !== 'mailhog',
    from: fromAddress(),
  }
}

// ─── Internal endpoints — called by other services, not the API Gateway ───────

// GET /health — liveness PLUS an honest delivery-config probe: email + WhatsApp config,
// and every reason delivery will not happen. Watching this output is how an operator
// proves the channels are wired before a notify button is ever clicked, instead of
// discovering after the fact that SMTP_HOST was still mailhog and WhatsApp still stubbed.
app.get('/health', (_req, res) => {
  const mail = emailConfig()
  const wa = getWhatsAppConfig()
  const warnings: string[] = []
  if (!mail.configured) {
    warnings.push(
      `email NOT configured: SMTP_HOST='${mail.host}' is the mailhog dev default. ` +
        `Set SMTP_HOST (+SMTP_PORT, SMTP_USER, SMTP_PASS, SMTP_SECURE) and EMAIL_FROM in the service environment.`
    )
  }
  if (!wa.configured) {
    warnings.push(
      `whatsapp NOT configured: provider='${wa.provider}'. No message has ever been sent; ` +
        `sender would be ${wa.from}. ${wa.hint}`
    )
  }
  res.json({ status: 'ok', service: 'notification-service', email: mail, whatsapp: wa, warnings })
})

// POST /notify/absentees — multi-channel fan-out (email + WhatsApp) for absentees: lecturers who
// didn't teach, or employees who didn't check in. recipients: [{ name, email, phone }]. WhatsApp is
// a no-op-with-log until provider creds are set (see whatsapp.ts). Called by a scheduler ~10 minutes
// after a session/shift ends.
app.post('/notify/absentees', async (req, res) => {
  const { recipients = [], subject, message, branding } = req.body ?? {}
  let emailed = 0, whatsapped = 0, failed = 0
  if (!emailConfig().configured) {
    console.warn(`[notify] absentees: email will FAIL — SMTP_HOST is the mailhog default (${emailConfig().host}), set a real relay`)
  }
  if (!getWhatsAppConfig().configured) {
    console.warn(`[notify] absentees: whatsapp stubbed (provider='${getWhatsAppConfig().provider}'), sender ${getWhatsAppConfig().from}`)
  }
  for (const rcpt of recipients as { name?: string; email?: string; phone?: string }[]) {
    if (rcpt.email) {
      try {
        await transporter.sendMail({
          from: fromAddress(branding?.domain),
          to: rcpt.email,
          subject: subject ?? 'QAAT notification',
          text: message ?? '',
        })
        emailed++
      } catch (e) {
        failed++
        console.warn(`[notify] absentee email FAILED for ${rcpt.email}`, e)
      }
    }
    if (rcpt.phone && await sendWhatsApp(rcpt.phone, message ?? '')) whatsapped++
  }
  console.info(`[notify] absentees: ${recipients.length} recipient(s), ${emailed} emailed, ${whatsapped} whatsapped, ${failed} failed`)
  res.json({ status: 'SENT', total: recipients.length, emailed, whatsapped })
})

// POST /notify/direct — one message to named people, over email and WhatsApp.
//
// WHY THIS EXISTS SEPARATELY FROM /notify/absentees. That endpoint is shaped around one
// specific report: it takes a list of people who failed to do something and says so. The
// employee attendance alerts are the same two transports carrying different content — a
// late check-in, a reminder to clock out — and squeezing them through an "absentees" route
// meant every future alert would inherit a name and a shape that no longer described it.
//
// Both transports are best-effort and independent: an employee with a phone but no email
// still gets the WhatsApp, and one unreachable address never fails the batch. The gateway
// has already recorded the alert as sent before calling here, so a delivery failure is
// logged rather than retried — a duplicate alert is worse than a missed one.
app.post('/notify/direct', async (req, res) => {
  const { recipients = [], subject, message, tenant, branding } = req.body ?? {}
  let emailed = 0, whatsapped = 0, failed = 0
  if (!emailConfig().configured) {
    console.warn(`[notify] direct: email will FAIL — SMTP_HOST is the mailhog default (${emailConfig().host}), set a real relay`)
  }
  if (!getWhatsAppConfig().configured) {
    console.warn(`[notify] direct: whatsapp stubbed (provider='${getWhatsAppConfig().provider}'), sender ${getWhatsAppConfig().from}`)
  }
  for (const rcpt of recipients as { name?: string; email?: string; phone?: string }[]) {
    const greeting = rcpt.name ? `Dear ${rcpt.name},\n\n` : ''
    const signature = tenant ? `\n\n— ${tenant} Quality Assurance` : ''
    const body = `${greeting}${message ?? ''}${signature}`
    if (rcpt.email) {
      try {
        await transporter.sendMail({
          from: fromAddress(branding?.domain),
          to: rcpt.email,
          subject: subject ?? 'QAAT notification',
          text: body,
        })
        emailed++
      } catch (e) {
        failed++
        console.warn(`[notify] direct email FAILED for ${rcpt.email}`, e)
      }
    }
    if (rcpt.phone && await sendWhatsApp(rcpt.phone, body)) whatsapped++
  }
  console.info(`[notify] direct: ${recipients.length} recipient(s), ${emailed} emailed, ${whatsapped} whatsapped, ${failed} failed`)
  res.json({ status: 'SENT', total: recipients.length, emailed, whatsapped, failed })
})

// POST /notify/test-send — the operator's proof that the channels deliver. Sends one test
// email and/or one test WhatsApp to the addresses given, and reports per channel whether
// it actually went out. It is disabled until NOTIFY_TEST_KEY is set in the environment
// (otherwise a public internal service would be an open relay); callers present it in the
// X-Notify-Test-Key header.
//
//   curl -X POST https://kiu-qaat-notify.onrender.com/notify/test-send \
//        -H 'Content-Type: application/json' -H 'X-Notify-Test-Key: <KEY>' \
//        -d '{"email":"ops@kiu.ac.ug","phone":"0786713144"}'
app.post('/notify/test-send', async (req, res) => {
  const testKey = process.env.NOTIFY_TEST_KEY
  if (!testKey) {
    res.status(503).json({ error: 'NOTIFY_TEST_DISABLED', hint: 'set NOTIFY_TEST_KEY in the service environment to enable /notify/test-send' })
    return
  }
  if (req.header('X-Notify-Test-Key') !== testKey) {
    res.status(401).json({ error: 'UNAUTHORIZED' })
    return
  }
  const { email, phone } = req.body ?? {}
  const subject = 'QAAT delivery test'
  const message = `QAAT test message. If you are reading this, the ${email && phone ? 'email and WhatsApp' : email ? 'email' : 'WhatsApp'} channel is delivering.\n\n— QAAT`
  const out: Record<string, unknown> = { config: { email: emailConfig(), whatsapp: getWhatsAppConfig() } }

  const mail = emailConfig()
  if (!mail.configured) {
    out.email = { attempted: email ? true : false, ok: false, error: `SMTP not configured (SMTP_HOST='${mail.host}')` }
  } else if (email) {
    try {
      await transporter.sendMail({ from: mail.from, to: email, subject, text: message })
      console.info(`[notify] test email sent to ${email} from ${mail.from}`)
      out.email = { attempted: true, ok: true }
    } catch (e) {
      console.warn(`[notify] test email FAILED for ${email}`, e)
      out.email = { attempted: true, ok: false, error: (e as Error).message }
    }
  } else {
    out.email = { attempted: false, note: 'no email address given' }
  }

  const wa = getWhatsAppConfig()
  if (phone && wa.configured) {
    const ok = await sendWhatsApp(phone, message)
    console.info(`[notify] test whatsapp to ${phone} from ${wa.from}: ${ok ? 'sent' : 'rejected'}`)
    out.whatsapp = { attempted: true, ok, error: ok ? undefined : 'provider rejected the send (see log)' }
  } else if (phone) {
    out.whatsapp = { attempted: true, ok: false, error: `whatsapp not configured (provider='${wa.provider}'). ${wa.hint} Sender: ${wa.from}` }
  } else {
    out.whatsapp = { attempted: false, note: 'no phone number given' }
  }

  res.json(out)
})

// POST /notify/sync-overdue
app.post('/notify/sync-overdue', async (req, res) => {
  const { to, coordinator_name, session_date, branding, push_subscription } = req.body
  try {
    await transporter.sendMail({
      from:    fromAddress(branding?.domain),
      to,
      subject: `[${branding.name}] Sync Overdue — Action Required`,
      html:    syncOverdueEmail(branding, coordinator_name, session_date),
    })
    if (push_subscription) {
      await sendSyncOverduePush(push_subscription, session_date).catch(console.warn)
    }
    res.json({ status: 'SENT' })
  } catch (e) {
    console.error('sync-overdue notification failed', e)
    res.status(500).json({ error: 'SEND_FAILED' })
  }
})

// POST /notify/qr-reissued
app.post('/notify/qr-reissued', async (req, res) => {
  const { to, student_name, reason, branding, qr_attachment } = req.body
  try {
    await transporter.sendMail({
      from:    fromAddress(branding?.domain),
      to,
      subject: `[${branding.name}] Your QR Code Has Been Reissued`,
      html:    qrReissuedEmail(branding, student_name, reason),
      attachments: qr_attachment ? [{
        filename:    `qr-${Date.now()}.png`,
        content:     Buffer.from(qr_attachment, 'base64'),
        contentType: 'image/png',
      }] : [],
    })
    res.json({ status: 'SENT' })
  } catch (e) {
    console.error('qr-reissued notification failed', e)
    res.status(500).json({ error: 'SEND_FAILED' })
  }
})

// POST /notify/warden-data
app.post('/notify/warden-data', async (req, res) => {
  const { to, coordinator_name, unit_name, branding, push_subscription } = req.body
  try {
    await transporter.sendMail({
      from:    fromAddress(branding?.domain),
      to,
      subject: `[${branding.name}] Warden Attendance Data Ready`,
      html:    wardenDataReceivedEmail(branding, coordinator_name, unit_name),
    })
    if (push_subscription) {
      await sendWardenDataPush(push_subscription, unit_name).catch(console.warn)
    }
    res.json({ status: 'SENT' })
  } catch (e) {
    console.error('warden-data notification failed', e)
    res.status(500).json({ error: 'SEND_FAILED' })
  }
})

const port = process.env.PORT ?? 3004
app.listen(port, () => {
  console.info(`notification-service listening on :${port}`)
  const mail = emailConfig()
  console.info(`[mail] SMTP_HOST=${mail.host} port=${mail.port} secure=${mail.secure} user=${mail.userSet ? 'set' : 'unset'} from=${mail.from} configured=${mail.configured}`)
  const wa = getWhatsAppConfig()
  console.info(`[whatsapp] provider=${wa.provider} from=${wa.from} configured=${wa.configured}${wa.configured ? '' : ' — ' + wa.hint}`)
})
