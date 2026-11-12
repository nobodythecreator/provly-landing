// supabase/functions/signup-notify/index.ts — v20.0.47
//
// Sends three emails, all through Resend from no-reply@getprovly.com:
//   • sign-up alert       → the platform owner (platform_settings.signup_alert_to); Reply-To = the new owner
//   • stuck sign-up alert → the platform owner; Reply-To = the stuck login's email
//   • welcome email       → the new provider's owner; Reply-To = platform_settings.welcome_reply_to
//
// Called once a minute by public.signup_notify_tick() (pg_cron + pg_net), and only when
// something is due. It takes no input: it claims due rows from public.signup_events,
// sends, and reports each result back. A call carrying the wrong x-provly-notify secret is
// refused. Each email carries a stable Resend idempotency key (row id + which email), so a
// retry after a crash cannot send it twice.
//
// None of these emails contains client (health) information: only business contact
// details, how the provider heard about Provly, and where their visit came from.
//
// Deploy (after the SQL has run and the PR is merged):
//   supabase functions deploy signup-notify --no-verify-jwt --project-ref zsrnqbmzgypldraifjho
// Uses the existing RESEND_API_KEY secret; SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are built in.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";

const FROM_ALERT = "Provly <no-reply@getprovly.com>";
const FROM_WELCOME = "Tombé at Provly <no-reply@getprovly.com>";
const SIGN_IN_URL = "https://getprovly.com/app";
const TZ = "America/Denver";

// ── Types ────────────────────────────────────────────────────────────
type Touch = {
  ref?: string; page?: string; at?: string;
  utm_source?: string; utm_medium?: string; utm_campaign?: string; utm_term?: string; utm_content?: string;
} | null;

type SignupEvent = {
  id: number;
  kind: "new_org" | "stuck_signup";
  alert_status: string;
  welcome_status: string;
  attempts: number;
  org: {
    name: string | null; address: string | null; phone: string | null; email: string | null;
    contract_number: string | null; trial_ends_at: string | null; created_at: string | null;
  } | null;
  owner: { first_name: string | null; last_name: string | null; email: string | null } | null;
  source: { heard_via: string | null; heard_detail: string | null; first_touch: Touch; signup_touch: Touch } | null;
  login: { email: string | null; created_at: string | null; signup_kind: string | null; invited_by: string | null } | null;
};

type Settings = { signup_alert_to?: string; welcome_reply_to?: string; welcome_enabled?: string };

export type Email = { to: string; from: string; reply_to?: string; subject: string; html: string; text: string };

type Outcome = "sent" | "skipped" | "failed" | "retry";

// ── Small helpers ────────────────────────────────────────────────────
export function esc(v: unknown): string {
  return String(v ?? "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

// Header-safe one-liner (no CR/LF), capped.
function oneLine(v: unknown, max = 150): string {
  return String(v ?? "").replace(/[\r\n\t]+/g, " ").replace(/\s{2,}/g, " ").trim().slice(0, max);
}

const EMAIL_RE = /^[^\s@<>"',;]+@[^\s@<>"',;]+\.[^\s@<>"',;]+$/;
export function cleanEmail(v: unknown): string | null {
  const s = String(v ?? "").trim();
  return s.length <= 254 && EMAIL_RE.test(s) ? s : null;
}

function telHref(phone: string): string | null {
  const digits = phone.replace(/[^\d+]/g, "");
  return digits.replace(/\+/g, "").length >= 7 ? `tel:${digits}` : null;
}

function mountain(iso: string | null | undefined, withTime: boolean): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (isNaN(d.getTime())) return "";
  const opts: Intl.DateTimeFormatOptions = withTime
    ? { timeZone: TZ, month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit", timeZoneName: "short" }
    : { timeZone: TZ, month: "long", day: "numeric", year: "numeric" };
  return new Intl.DateTimeFormat("en-US", opts).format(d);
}

function shortDate(iso: string | null | undefined): string {
  if (!iso) return "";
  const d = new Date(iso);
  return isNaN(d.getTime()) ? "" : new Intl.DateTimeFormat("en-US", { timeZone: TZ, month: "short", day: "numeric" }).format(d);
}

export const HEARD_LABELS: Record<string, string> = {
  google: "Google search",
  ai_assistant: "An AI assistant",
  provider_referral: "Another provider recommended it",
  support_coordinator: "A support coordinator or DSPD",
  provly_outreach: "Someone from Provly reached out",
  event: "An event, training or association",
  social: "Social media",
  other: "Other",
};

export function heardLine(src: SignupEvent["source"]): string {
  if (!src || !src.heard_via) return "Not answered";
  const label = HEARD_LABELS[src.heard_via] ?? src.heard_via;
  return src.heard_detail ? `${label}: "${src.heard_detail}"` : label;
}

export function touchLine(t: Touch): string {
  if (!t) return "Not recorded";
  const from = t.utm_source
    ? `campaign tag "${t.utm_source}"${t.utm_campaign ? ` (${t.utm_campaign})` : ""}`
    : t.ref ? t.ref.replace(/^www\./, "").replace(/\/$/, "") : "direct (typed the address or a bookmark)";
  const parts = [from];
  if (t.page) parts.push(t.page.replace(/\/$/, "") || t.page);
  const day = shortDate(t.at);
  if (day) parts.push(day);
  return parts.join(" · ");
}

function row(label: string, valueHtml: string): string {
  return `<tr><td style="padding:6px 14px 6px 0;color:#555;vertical-align:top;white-space:nowrap">${esc(label)}</td>` +
         `<td style="padding:6px 0;color:#111;vertical-align:top">${valueHtml}</td></tr>`;
}

function shell(titleHtml: string, bodyHtml: string): string {
  return `<!doctype html><html><body style="margin:0;padding:24px;background:#fff;font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;color:#111">` +
         `<div style="max-width:560px">${titleHtml}${bodyHtml}</div></body></html>`;
}

// ── Email builders ───────────────────────────────────────────────────
export function buildSignupAlert(ev: SignupEvent, to: string): Email {
  const o = ev.org ?? { name: null, address: null, phone: null, email: null, contract_number: null, trial_ends_at: null, created_at: null };
  const w = ev.owner ?? { first_name: null, last_name: null, email: null };
  const orgName = oneLine(o.name) || "(no name)";
  const ownerName = oneLine([w.first_name, w.last_name].filter(Boolean).join(" ")) || "(no name)";
  const ownerEmail = cleanEmail(w.email);
  const orgEmail = cleanEmail(o.email);
  const phone = oneLine(o.phone, 40);
  const tel = phone ? telHref(phone) : null;
  const mail = (e: string | null) => e ? `<a href="mailto:${esc(encodeURIComponent(e).replace(/%40/g, "@"))}">${esc(e)}</a>` : "";

  const rows = [
    row("Organization", `<strong>${esc(orgName)}</strong>`),
    row("Address", esc(o.address)),
    row("Phone", tel ? `<a href="${esc(tel)}">${esc(phone)}</a>` : esc(phone)),
    row("Org email", mail(orgEmail) || esc(o.email)),
    row("DSPD contract", esc(o.contract_number)),
    row("Owner", esc(ownerName)),
    row("Owner login", mail(ownerEmail) || esc(w.email)),
    row("How they heard", esc(heardLine(ev.source))),
    row("First visit", esc(touchLine(ev.source?.first_touch ?? null))),
    row("Signed up from", esc(touchLine(ev.source?.signup_touch ?? null))),
    row("Trial", esc(`Started ${mountain(o.created_at, false)} · ends ${mountain(o.trial_ends_at, false)}`)),
    row("Signed up at", esc(mountain(o.created_at, true))),
  ].join("");

  const replyNote = ownerEmail ? `Reply to this email to write to ${ownerEmail}.` : "";
  const html = shell(
    `<h2 style="margin:0 0 4px;font-size:20px">New Provly sign-up</h2><p style="margin:0 0 16px;color:#555">${esc(orgName)} just started a trial.</p>`,
    `<table style="border-collapse:collapse;margin-bottom:16px">${rows}</table>` +
    (replyNote ? `<p style="margin:0;color:#555">${esc(replyNote)}</p>` : ""));

  const text = [
    `New Provly sign-up: ${orgName}`, "",
    `Organization:   ${orgName}`,
    `Address:        ${oneLine(o.address, 300)}`,
    `Phone:          ${phone}`,
    `Org email:      ${oneLine(o.email, 254)}`,
    `DSPD contract:  ${oneLine(o.contract_number, 100)}`,
    `Owner:          ${ownerName}`,
    `Owner login:    ${oneLine(w.email, 254)}`,
    `How they heard: ${heardLine(ev.source)}`,
    `First visit:    ${touchLine(ev.source?.first_touch ?? null)}`,
    `Signed up from: ${touchLine(ev.source?.signup_touch ?? null)}`,
    `Trial:          started ${mountain(o.created_at, false)}, ends ${mountain(o.trial_ends_at, false)}`,
    `Signed up at:   ${mountain(o.created_at, true)}`,
    "", replyNote,
  ].join("\n");

  return { to, from: FROM_ALERT, reply_to: ownerEmail ?? undefined, subject: oneLine(`New Provly sign-up: ${orgName}`), html, text };
}

export function buildStuckAlert(ev: SignupEvent, to: string): Email {
  const l = ev.login ?? { email: null, created_at: null, signup_kind: null, invited_by: null };
  const email = cleanEmail(l.email);
  const shown = email ?? (oneLine(l.email, 254) || "(no email)");
  const when = mountain(l.created_at, true);
  const invitedBy = oneLine(l.invited_by, 200);
  const what = l.signup_kind === "invite"
    ? `They were joining ${invitedBy || "an existing customer"} through an invite, and the joining step didn't finish.`
    : l.signup_kind === "provider"
      ? "They were signing up a new provider, and the organization step didn't finish."
      : "Provly couldn't tell whether they were signing up a new provider or joining a customer.";
  const lines = [
    `${shown} created a Provly login${when ? ` on ${when}` : ""} and still had no organization 15 minutes later.`,
    what,
    email ? `Reply to this email to write to ${email}.` : "",
  ].filter(Boolean);

  const html = shell(
    `<h2 style="margin:0 0 12px;font-size:20px">Action needed: stuck sign-up</h2>`,
    lines.map((p) => `<p style="margin:0 0 12px">${esc(p)}</p>`).join(""));
  const text = [`Action needed: stuck Provly sign-up: ${shown}`, ...lines].join("\n\n");

  return { to, from: FROM_ALERT, reply_to: email ?? undefined, subject: oneLine(`Action needed: stuck Provly sign-up: ${shown}`), html, text };
}

// null = nothing to send (no owner email to send to).
export function buildWelcome(ev: SignupEvent, replyTo: string | null): Email | null {
  const w = ev.owner;
  const to = cleanEmail(w?.email);
  if (!to) return null;
  const first = oneLine(w?.first_name, 60);
  const orgName = oneLine(ev.org?.name, 150) || "your organization";
  const ends = mountain(ev.org?.trial_ends_at, false);

  const paras = [
    `Hi ${first || "there"},`,
    `Thanks for starting Provly for ${orgName}. Your free 30-day trial is live${ends ? ` through ${ends}` : ""}, with every module included.`,
    `Sign in any time at getprovly.com/app`,
    `I'd like to give you a free 20–30 minute walkthrough. We'll set up your first clients and staff together and make sure Provly fits the way you work. Just reply with a couple of times that work for you.`,
    `Provly was built in partnership with a Utah DSPD provider, so it's shaped around what audits, UPI billing and EVV actually take. Any question you have, reply here and it comes straight to me.`,
  ];
  const signature = ["Tombé Mogga", "Founder, Provly", "getprovly.com"];

  const html = shell("",
    paras.map((p) => p.startsWith("Sign in any time")
      ? `<p style="margin:0 0 14px">Sign in any time at <a href="${SIGN_IN_URL}">getprovly.com/app</a></p>`
      : `<p style="margin:0 0 14px">${esc(p)}</p>`).join("") +
    `<p style="margin:18px 0 0">${signature.map(esc).join("<br>")}</p>`);
  const text = [...paras, signature.join("\n")].join("\n\n");

  return {
    to, from: FROM_WELCOME, reply_to: replyTo ?? undefined,
    subject: first ? oneLine(`Welcome to Provly, ${first}`) : "Welcome to Provly",
    html, text,
  };
}

// ── IO ───────────────────────────────────────────────────────────────
async function rpc(name: string, args: Record<string, unknown>): Promise<unknown> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`${name} failed (${res.status}): ${body.slice(0, 300)}`);
  return body ? JSON.parse(body) : null;
}

async function send(email: Email, idempotencyKey: string): Promise<{ outcome: Outcome; error?: string }> {
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${RESEND_API_KEY}`,
        "Content-Type": "application/json",
        "Idempotency-Key": idempotencyKey,
      },
      body: JSON.stringify({
        from: email.from, to: [email.to], subject: email.subject, html: email.html, text: email.text,
        ...(email.reply_to ? { reply_to: email.reply_to } : {}),
      }),
    });
    if (res.ok) return { outcome: "sent" };
    const body = (await res.text()).slice(0, 300);
    // 409: this idempotency key was already used. A concurrent duplicate is still in flight
    // (retry later); otherwise the email already went out under this key.
    if (res.status === 409) return /concurrent/i.test(body) ? { outcome: "retry", error: `Resend 409: ${body}` } : { outcome: "sent" };
    if (res.status === 429 || res.status >= 500) return { outcome: "retry", error: `Resend ${res.status}: ${body}` };
    return { outcome: "failed", error: `Resend ${res.status}: ${body}` };
  } catch (e) {
    return { outcome: "retry", error: `Resend unreachable: ${e instanceof Error ? e.message : String(e)}` };
  }
}

export async function processEvent(ev: SignupEvent, settings: Settings): Promise<{ id: number; alert: Outcome | null; welcome: Outcome | null }> {
  let alert: Outcome | null = null;
  let welcome: Outcome | null = null;
  const errors: string[] = [];
  try {
    if (ev.alert_status === "pending") {
      const to = cleanEmail(settings.signup_alert_to);
      if (!to) { alert = "retry"; errors.push("platform_settings.signup_alert_to is missing or not an email"); }
      else if (ev.kind === "new_org" && !ev.org) { alert = "failed"; errors.push("organization no longer exists"); }
      else {
        const email = ev.kind === "new_org" ? buildSignupAlert(ev, to) : buildStuckAlert(ev, to);
        const r = await send(email, `provly-signup-${ev.id}-alert`);
        alert = r.outcome; if (r.error) errors.push(r.error);
      }
    }
    if (ev.kind === "new_org" && ev.welcome_status === "pending") {
      if (settings.welcome_enabled !== "true") welcome = "skipped";
      else {
        const email = buildWelcome(ev, cleanEmail(settings.welcome_reply_to));
        if (!email) welcome = "skipped";
        else {
          const r = await send(email, `provly-signup-${ev.id}-welcome`);
          welcome = r.outcome; if (r.error) errors.push(r.error);
        }
      }
    }
  } catch (e) {
    errors.push(e instanceof Error ? e.message : String(e));
    if (ev.alert_status === "pending" && alert === null) alert = "retry";
    if (ev.kind === "new_org" && ev.welcome_status === "pending" && welcome === null) welcome = "retry";
  }
  await rpc("signup_outbox_report", { p_id: ev.id, p_alert: alert, p_welcome: welcome, p_error: errors.join(" | ") || null });
  return { id: ev.id, alert, welcome };
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

export async function handle(req: Request): Promise<Response> {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  if (!SUPABASE_URL || !SERVICE_KEY || !RESEND_API_KEY) return json({ error: "function is missing its configuration" }, 500);
  try {
    const ok = await rpc("signup_notify_authorized", { p_secret: req.headers.get("x-provly-notify") ?? "" });
    if (ok !== true) return json({ error: "unauthorized" }, 401);
    const batch = (await rpc("signup_outbox_claim", { p_limit: 10 })) as { settings?: Settings; events?: SignupEvent[] } | null;
    const settings = batch?.settings ?? {};
    const results = [];
    for (const ev of batch?.events ?? []) {
      try { results.push(await processEvent(ev, settings)); }
      catch (e) { console.error(`signup-notify: event ${ev.id}:`, e); }   // its claim lapses; it is retried
    }
    return json({ processed: results.length, results });
  } catch (e) {
    console.error("signup-notify:", e);
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
}

Deno.serve(handle);
