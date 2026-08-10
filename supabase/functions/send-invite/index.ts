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

    // v20.0.3 — DELIVERY-FIRST supersede. The new invite is created and its
    // email delivered while any prior pending invite remains untouched and
    // usable; only after confirmed delivery are older pendings revoked.
    // Failure residue is therefore SAFE in every branch:
    //   * insert fails  -> nothing changed; the prior link still works
    //   * email fails   -> best-effort delete of the undelivered row; even
    //                      if that also fails, the leftover is inert (never
    //                      emailed, unguessable token, email-match enforced
    //                      at accept, ages out at expiry) and the prior link
    //                      still works
    //   * post-delivery revoke fails -> the recipient briefly holds two
    //                      working links; the next successful invite or
    //                      expiry supersedes them
    // No cleanup step is load-bearing for the recipient's access — the only
    // honest guarantee available across a non-transactional email boundary.
    // (Requires v20.0.3.2: the pending-unique index is dropped; and
    // v20.0.3.3/.4: get_invite + accept_invite enforce newest-pending-wins
    // under the total order (created_at, id), so acceptance correctness
    // never depends on any revocation in this function — even on ties.)

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
      .select("id, expires_at, created_at")
      .single();

    if (invErr) {
      // Nothing was changed — the prior invite (if any) is untouched.
      console.error("invite insert failed:", invErr);
      return json({ error: "Could not create invite" }, 500);
    }

    // Send via Resend.
    const inviteUrl = `https://getprovly.com/app?invite=${invite.id}`;
    const inviterName = [callerStaff.first_name, callerStaff.last_name]
      .filter(Boolean).join(" ") || "An administrator";

    let sendRes: Response | null = null;
    try {
      sendRes = await fetch("https://api.resend.com/emails", {
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
    } catch (sendErr) {
      // Round-4 finding: a network-level rejection makes fetch THROW with no
      // response object — previously that escaped to the outer catch and
      // skipped cleanup, leaving the prior invite revoked and the
      // replacement undelivered. Caught here so both failure shapes
      // (thrown transport error, non-ok HTTP response) share one cleanup.
      console.error("Resend transport failure (fetch threw):", sendErr);
    }

    if (!sendRes || !sendRes.ok) {
      const detail = sendRes
        ? await sendRes.text().catch(() => "")
        : "no response (transport failure)";
      console.error("Resend send failed:", sendRes ? sendRes.status : "-", detail);
      // Best-effort hygiene: remove the undelivered row. The prior invite
      // was never touched, so the recipient's usable link is intact even if
      // this delete fails (the leftover row is inert — see doctrine above).
      try {
        const { error: delErr } = await admin.from("invites").delete().eq("id", invite.id);
        if (delErr) console.error("undelivered-invite cleanup returned error (harmless):", delErr);
      } catch (delThrow) {
        console.error("undelivered-invite cleanup threw (harmless):", delThrow);
      }
      return json({ error: "Invite email could not be sent" }, 502);
    }

    // Delivery confirmed — supersede STRICTLY OLDER pendings only (round 6):
    // .lt(created_at) means concurrent sends can never revoke each other's
    // newest link (the newest row is older than nothing). And correctness
    // does not depend on this succeeding at all: accept_invite enforces
    // NEWEST-PENDING-WINS transactionally (v20.0.3.3), so a stale link —
    // including a higher-role one — dies at acceptance regardless. This
    // revocation is hygiene. supabase-js reports failures by RESOLVING with
    // { error } (it does not throw), so both shapes are checked and logged.
    try {
      // Two updates = strictly-less in the TOTAL order (created_at, id):
      // (1) strictly older timestamps; (2) tied timestamps with a lower id.
      // Matches the accept-side guard exactly, so the newest-by-total-order
      // invite can never be revoked by a peer send — including on ties
      // (round-7 finding). Still pure hygiene: accept enforces the order.
      const { error: supErr1 } = await admin
        .from("invites")
        .update({ revoked_at: new Date().toISOString() })
        .eq("org_id", callerStaff.org_id)
        .eq("email", email)
        .is("accepted_at", null)
        .is("revoked_at", null)
        .lt("created_at", invite.created_at);
      if (supErr1) {
        console.error("supersede pass 1 returned error (harmless — order enforced at accept):", supErr1);
      }
      const { error: supErr2 } = await admin
        .from("invites")
        .update({ revoked_at: new Date().toISOString() })
        .eq("org_id", callerStaff.org_id)
        .eq("email", email)
        .is("accepted_at", null)
        .is("revoked_at", null)
        .eq("created_at", invite.created_at)
        .lt("id", invite.id);
      if (supErr2) {
        console.error("supersede pass 2 returned error (harmless — order enforced at accept):", supErr2);
      }
    } catch (superErr) {
      console.error("post-delivery supersede threw (harmless — order enforced at accept):", superErr);
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
