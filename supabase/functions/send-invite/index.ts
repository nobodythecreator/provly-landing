// supabase/functions/send-invite/index.ts
// Provly v20.0.3 — create an invite row and send the invite email via Resend.
//
// Caller: an authenticated owner/admin in the app (JWT verified by the
// platform — deploy WITHOUT --no-verify-jwt, unlike stripe-webhook).
// Flow: validate caller role -> insert invites row (service role) -> send
// email via Resend -> return { ok, inviteId }. If the email send fails, the
// invite row is deleted so the UI failure state is honest.
//
// PHI rule: the email carries a person's name, an org name, a role, and a
// link. Nothing else, ever.

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

// Roles invitable in v20.0.3 — the user_role enum minus "owner", from the
// live-DB diagnostic. Items 3-4 ALTER TYPE to add hhs_operator (with scope);
// v20.5 adds care-circle roles. 'owner' is never invitable (DB CHECK agrees).
const ALLOWED_INVITE_ROLES = [
  "admin", "supervisor", "dsp", "billing", "readonly", "bcba", "rn",
  "house_manager", "day_program_director", "residential_director",
  "compliance_director",
];
// Roles allowed to SEND invites.
const CAN_INVITE = ["owner", "admin"];

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const jwt = authHeader.replace(/^Bearer\s+/i, "");
    if (!jwt) return json({ error: "Not authenticated" }, 401);

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const resendKey = Deno.env.get("RESEND_API_KEY");
    if (!resendKey) return json({ error: "Email is not configured" }, 500);

    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false },
    });

    // Who is calling?
    const { data: userData, error: userErr } = await admin.auth.getUser(jwt);
    if (userErr || !userData?.user) return json({ error: "Not authenticated" }, 401);
    const caller = userData.user;

    // Caller's staff record -> org + role gate.
    const { data: callerStaff } = await admin
      .from("staff")
      .select("org_id, role, first_name, last_name")
      .eq("user_id", caller.id)
      .eq("is_active", true)
      .maybeSingle();
    if (!callerStaff) return json({ error: "No active staff record" }, 403);
    if (!CAN_INVITE.includes(callerStaff.role)) {
      return json({ error: "Only owners and admins can send invites" }, 403);
    }

    // Payload.
    const body = await req.json().catch(() => ({}));
    const email = String(body.email ?? "").trim().toLowerCase();
    const role = String(body.role ?? "dsp").trim();
    const firstName = String(body.firstName ?? "").trim();
    const lastName = String(body.lastName ?? "").trim();

    if (!EMAIL_RE.test(email)) return json({ error: "Invalid email address" }, 400);
    if (!ALLOWED_INVITE_ROLES.includes(role)) {
      return json({ error: `Role must be one of: ${ALLOWED_INVITE_ROLES.join(", ")}` }, 400);
    }

    // Org identity for the email body (name only — no PHI ever leaves here).
    const { data: org } = await admin
      .from("organizations")
      .select("name, legal_name, display_name, email")
      .eq("id", callerStaff.org_id)
      .maybeSingle();
    const orgName = org?.display_name || org?.legal_name || org?.name || "your organization";

    // Create the invite row (service role; RLS bypassed by design here).
    const { data: invite, error: invErr } = await admin
      .from("invites")
      .insert({
        org_id: callerStaff.org_id,
        email,
        first_name: firstName || null,
        last_name: lastName || null,
        role,
        invited_by: caller.id,
      })
      .select("id, expires_at")
      .single();

    if (invErr) {
      // 23505 = the partial unique index: a pending invite already exists.
      if ((invErr as { code?: string }).code === "23505") {
        return json({ error: "A pending invite already exists for that email" }, 409);
      }
      console.error("invite insert failed:", invErr);
      return json({ error: "Could not create invite" }, 500);
    }

    // Send via Resend.
    const inviteUrl = `https://getprovly.com/app?invite=${invite.id}`;
    const inviterName = [callerStaff.first_name, callerStaff.last_name]
      .filter(Boolean).join(" ") || "An administrator";

    const sendRes = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${resendKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: "Provly <invites@getprovly.com>",
        to: [email],
        ...(org?.email ? { reply_to: org.email } : {}),
        subject: `You're invited to join ${orgName} on Provly`,
        html: `
          <div style="font-family: -apple-system, Segoe UI, Roboto, sans-serif; max-width: 520px; margin: 0 auto; color: #0A1E33;">
            <h2 style="color: #0A1E33;">You're invited to ${escapeHtml(orgName)}</h2>
            <p>${escapeHtml(inviterName)} has invited you${firstName ? `, ${escapeHtml(firstName)},` : ""} to join
            <strong>${escapeHtml(orgName)}</strong> on Provly as <strong>${escapeHtml(role)}</strong>.</p>
            <p style="margin: 28px 0;">
              <a href="${inviteUrl}"
                 style="background: #00897B; color: #ffffff; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-weight: 600;">
                Accept invitation
              </a>
            </p>
            <p style="font-size: 13px; color: #55657a;">This invitation expires in 7 days.
            If the button doesn't work, paste this link into your browser:<br>
            <a href="${inviteUrl}">${inviteUrl}</a></p>
            <p style="font-size: 13px; color: #55657a;">If you weren't expecting this invitation, you can safely ignore this email.</p>
          </div>
        `,
      }),
    });

    if (!sendRes.ok) {
      const detail = await sendRes.text().catch(() => "");
      console.error("Resend send failed:", sendRes.status, detail);
      // Honest failure: remove the row so the UI can say "not sent" truthfully.
      await admin.from("invites").delete().eq("id", invite.id);
      return json({ error: "Invite email could not be sent" }, 502);
    }

    return json({ ok: true, inviteId: invite.id, expiresAt: invite.expires_at });
  } catch (e) {
    console.error("send-invite unhandled:", e);
    return json({ error: "Unexpected error" }, 500);
  }
});

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] as string)
  );
}
