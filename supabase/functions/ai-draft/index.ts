// supabase/functions/ai-draft/index.ts
// v20.0.22 — the AI drafting proxy (arc: "AI drafting proxy").
//
// The AI page used to call api.anthropic.com from the browser with no key, so
// it never worked — and if it had, the key and the notes would have left from
// the user's browser. Now the browser asks THIS function for a draft; the
// function holds the Anthropic key, reads the notes itself, and returns text.
//
// Owner decisions (Sep 24):
//   D1 = A — health information goes to Anthropic only under a signed BAA.
//            Until AI_BAA_CONFIRMED is set to "true" (a function secret), this
//            function refuses every request. Only what the draft needs is sent:
//            the client's FIRST name, service codes, dates/times, note text,
//            and staff first names — never a last name, date of birth, Medicaid
//            number or address.
//   D2 = A — office leadership only at launch: owner, admin,
//            compliance_director (the roles whose navigation shows the page).
//
// Reads use the CALLER's own login (RLS applies), so a draft can only ever
// summarize notes the caller can already see. It accepts a client id and a
// period — never free text — so Provly's key cannot be used as a general
// chatbot. Each draft writes an audit_log row ('ai_draft') with ids and
// counts only, no health information.

import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

const AI_ROLES = ["owner", "admin", "compliance_director"];          // D2 = A
const MODEL = "claude-sonnet-5";
const MAX_NOTES = 200;
const MAX_NOTE_CHARS = { handoff: 1200, quarterly: 400 } as const;
const MAX_RANGE_DAYS = 184;                                           // two quarters

// Business dates are America/Denver (v20.0.14).
function denverToday(): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Denver", year: "numeric", month: "2-digit", day: "2-digit",
  }).format(new Date());
}
const isYmd = (s: unknown): s is string => typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s);
const dayDiff = (a: string, b: string) =>
  Math.round((Date.parse(b + "T00:00:00Z") - Date.parse(a + "T00:00:00Z")) / 86400000);

const SYSTEM = [
  "You draft documentation for a Utah DSPD (Division of Services for People with Disabilities) provider.",
  "Write in plain, professional, person-centered language, in the third person, using the client's first name.",
  "Use ONLY the service notes provided. Do not invent events, diagnoses, medications, goals or numbers.",
  "If the notes do not cover something, say so briefly instead of guessing.",
  "No preamble and no sign-off: return only the draft. A person will review and edit it before it is used.",
].join(" ");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    // D1 = A — the switch. Nothing is read or sent until the BAA is signed.
    if (Deno.env.get("AI_BAA_CONFIRMED") !== "true") {
      return json({ error: "AI drafting is switched off until Provly's Business Associate Agreement with Anthropic is in place." }, 503);
    }
    const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");
    if (!anthropicKey) return json({ error: "AI drafting is not configured" }, 500);

    const authHeader = req.headers.get("Authorization") ?? "";
    const jwt = authHeader.replace(/^Bearer\s+/i, "");
    if (!jwt) return json({ error: "Not authenticated" }, 401);

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
    // Every data read goes through the caller's own login, so RLS applies.
    const asUser = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false },
      global: { headers: { Authorization: `Bearer ${jwt}` } },
    });

    const { data: userData, error: userErr } = await admin.auth.getUser(jwt);
    if (userErr || !userData?.user) return json({ error: "Not authenticated" }, 401);
    const caller = userData.user;

    const { data: member } = await admin
      .from("org_members").select("org_id, role").eq("user_id", caller.id).maybeSingle();
    if (!member) return json({ error: "No organization membership for this login" }, 403);
    if (!AI_ROLES.includes(member.role)) {
      return json({ error: "AI drafting is available to owners, admins and the compliance director" }, 403);
    }

    let body: Record<string, unknown>;
    try { body = await req.json(); } catch { return json({ error: "Invalid request" }, 400); }
    const mode = body.mode;
    const personId = body.person_id;
    if (mode !== "handoff" && mode !== "quarterly") return json({ error: "Unknown draft type" }, 400);
    if (typeof personId !== "string" || !/^[0-9a-f-]{36}$/i.test(personId)) return json({ error: "Select a client" }, 400);

    let start: string, end: string;
    if (mode === "handoff") {
      start = end = denverToday();
    } else {
      if (!isYmd(body.start) || !isYmd(body.end)) return json({ error: "Choose a start and end date" }, 400);
      start = body.start; end = body.end;
      const span = dayDiff(start, end);
      if (span < 0) return json({ error: "The start date must be before the end date" }, 400);
      if (span > MAX_RANGE_DAYS) return json({ error: "Choose a period of six months or less" }, 400);
    }

    // The client — first name only (minimum necessary), read under RLS.
    const { data: person } = await asUser
      .from("persons").select("id, first_name").eq("id", personId).maybeSingle();
    if (!person) return json({ error: "Client not found" }, 404);

    const { data: notes, error: notesErr } = await asUser
      .from("service_notes")
      .select("service_date, start_time, end_time, summary_note, staff_id, service_code_definitions(code, name)")
      .eq("person_id", personId)
      .gte("service_date", start)
      .lte("service_date", end)
      .order("service_date").order("start_time")
      .limit(MAX_NOTES);
    if (notesErr) return json({ error: "Could not read the service notes" }, 500);
    if (!notes || notes.length === 0) {
      return json({ error: mode === "handoff"
        ? "No notes found for today — try a quarterly summary instead"
        : "No notes found in this date range" }, 404);
    }

    // Staff first names, from the coworker directory (v20.0.12 B3).
    const staffIds = [...new Set(notes.map((n) => n.staff_id).filter(Boolean))];
    const staffFirst: Record<string, string> = {};
    if (staffIds.length) {
      const { data: dir } = await asUser.from("staff_directory_v").select("id, first_name").in("id", staffIds);
      (dir || []).forEach((s) => { staffFirst[s.id] = s.first_name || ""; });
    }

    const cap = MAX_NOTE_CHARS[mode];
    const lines = notes.map((n) => {
      // deno-lint-ignore no-explicit-any
      const code = (n as any).service_code_definitions?.code || "?";
      const text = String(n.summary_note || "").slice(0, cap);
      if (mode === "handoff") {
        const t = `${String(n.start_time || "?").slice(0, 5)}-${String(n.end_time || "?").slice(0, 5)}`;
        return `${code} (${t}) by ${staffFirst[n.staff_id] || "staff"}: ${text}`;
      }
      return `${n.service_date} — ${code}: ${text}`;
    }).join("\n\n");

    const task = mode === "handoff"
      ? `Write a concise shift handoff for the incoming staff member supporting ${person.first_name}, based on today's notes (${start}). ` +
        "Cover: how the day went, anything the next shift must watch for or follow up on, and anything left unfinished. Short paragraphs or brief bullet points."
      : `Write a quarterly progress summary for ${person.first_name}'s support coordinator covering ${start} to ${end}. ` +
        "Cover: services delivered, progress and patterns seen in the notes, concerns or changes, and anything the coordinator should know. Plain paragraphs.";

    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": anthropicKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 1200,
        system: SYSTEM,
        messages: [{ role: "user", content: `${task}\n\nService notes:\n\n${lines}` }],
      }),
    });
    if (!res.ok) {
      console.error("ai-draft: Anthropic", res.status, await res.text().catch(() => ""));
      return json({ error: "The AI service did not respond. Try again in a minute." }, 502);
    }
    const data = await res.json();
    // deno-lint-ignore no-explicit-any
    const text = (data.content || []).map((c: any) => (c.type === "text" ? c.text : "")).join("").trim();
    if (!text) return json({ error: "No draft was generated. Try again." }, 502);

    // Audit — ids and counts only; no health information in the log.
    await admin.from("audit_log").insert({
      org_id: member.org_id, user_id: caller.id, action: "ai_draft", table_name: "service_notes",
      record_id: personId, new_data: { mode, start, end, note_count: notes.length, model: MODEL },
    });

    return json({ text, mode, start, end, noteCount: notes.length, clientFirstName: person.first_name });
  } catch (e) {
    console.error("ai-draft unhandled:", e);
    return json({ error: "Unexpected error" }, 500);
  }
});
