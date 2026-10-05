// Hisaably — send-push Edge Function (FCM HTTP v1 → Android + iOS/APNs)
//
// Called ONLY by the database: an AFTER INSERT trigger on `notifications`
// queues a pg_net request, which pg_net sends after the transaction commits
// (spec: "notifications only after server commit"). Body:
//   { "notification_ids": ["<uuid>", ...] }
// Auth: header `x-dispatch-secret` must equal the PUSH_DISPATCH_SECRET
// function secret (a random value also kept in Vault for the trigger).
//
// Push credentials: FCM_SERVICE_ACCOUNT = the Firebase service-account JSON
// (function secret, never in the repo or the app). Until it is set, this
// function answers { skipped: "push not configured" } and changes nothing —
// in-app notifications keep working without push.
//
// Invalid/unregistered device tokens are deactivated (spec §26).

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_IDS = 500;
const CONCURRENCY = 20;

type ServiceAccount = {
  project_id: string;
  client_email: string;
  private_key: string;
};

type NotificationRow = {
  id: string;
  recipient_id: string;
  group_id: string | null;
  transaction_id: string | null;
  type: string;
  title: string;
  body: string;
};

type DeviceRow = { id: string; user_id: string; device_token: string };

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function serviceClient(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new Error("Function environment is not configured");
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

// Constant-time comparison for the shared secret.
function safeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  if (ea.length !== eb.length) return false;
  let diff = 0;
  for (let i = 0; i < ea.length; i++) diff |= ea[i] ^ eb[i];
  return diff === 0;
}

// ---------------------------------------------------------------- Google auth

function base64url(data: Uint8Array | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToDer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out.buffer;
}

let cachedToken: { value: string; expiresAt: number } | null = null;

async function googleAccessToken(sa: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedToken.expiresAt - 60 > now) return cachedToken.value;

  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64url(
    JSON.stringify({
      iss: sa.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600,
    }),
  );
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      key,
      new TextEncoder().encode(`${header}.${claims}`),
    ),
  );
  const assertion = `${header}.${claims}.${base64url(signature)}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!res.ok) throw new Error(`Google token request failed (${res.status})`);
  const body = await res.json();
  cachedToken = { value: body.access_token, expiresAt: now + body.expires_in };
  return cachedToken.value;
}

// ---------------------------------------------------------------- FCM

type SendOutcome = "sent" | "invalid_token" | "failed";

async function sendOne(
  sa: ServiceAccount,
  accessToken: string,
  token: string,
  n: NotificationRow,
): Promise<SendOutcome> {
  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        message: {
          token,
          notification: { title: n.title, body: n.body },
          // Strings only (FCM data payload rule).
          data: {
            notification_id: n.id,
            type: n.type,
            group_id: n.group_id ?? "",
            transaction_id: n.transaction_id ?? "",
          },
          android: { priority: "high" },
          apns: { payload: { aps: { sound: "default" } } },
        },
      }),
    },
  );
  if (res.ok) return "sent";
  // Token no longer valid for this app/device → deactivate it.
  if (res.status === 404) return "invalid_token";
  if (res.status === 400) {
    const err = await res.json().catch(() => ({}));
    const details = JSON.stringify(err);
    if (details.includes("UNREGISTERED") || details.includes("registration token")) {
      return "invalid_token";
    }
  }
  return "failed";
}

async function inBatches<T>(items: T[], size: number, fn: (t: T) => Promise<void>) {
  for (let i = 0; i < items.length; i += size) {
    await Promise.all(items.slice(i, i + size).map(fn));
  }
}

// ---------------------------------------------------------------- handler

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") return json(405, { error: "Method not allowed" });

    const secret = Deno.env.get("PUSH_DISPATCH_SECRET") ?? "";
    const given = req.headers.get("x-dispatch-secret") ?? "";
    if (!secret || !safeEqual(given, secret)) {
      return json(401, { error: "Unauthorized" });
    }

    const payload = await req.json().catch(() => null);
    const ids: unknown = payload?.notification_ids;
    if (
      !Array.isArray(ids) ||
      ids.length === 0 ||
      ids.length > MAX_IDS ||
      !ids.every((id) => typeof id === "string" && UUID_RE.test(id))
    ) {
      return json(400, { error: "notification_ids must be 1–500 UUIDs" });
    }

    const saJson = Deno.env.get("FCM_SERVICE_ACCOUNT");
    if (!saJson) return json(200, { sent: 0, skipped: "push not configured" });
    const sa = JSON.parse(saJson) as ServiceAccount;

    const admin = serviceClient();
    const { data: notes, error: notesError } = await admin
      .from("notifications")
      .select("id, recipient_id, group_id, transaction_id, type, title, body")
      .in("id", ids);
    if (notesError) throw notesError;
    const notifications = (notes ?? []) as NotificationRow[];
    if (notifications.length === 0) return json(200, { sent: 0 });

    const recipients = [...new Set(notifications.map((n) => n.recipient_id))];
    const { data: devs, error: devError } = await admin
      .from("notification_devices")
      .select("id, user_id, device_token")
      .in("user_id", recipients)
      .eq("is_active", true);
    if (devError) throw devError;
    const devices = (devs ?? []) as DeviceRow[];

    const jobs: { n: NotificationRow; d: DeviceRow }[] = [];
    for (const n of notifications) {
      for (const d of devices) if (d.user_id === n.recipient_id) jobs.push({ n, d });
    }
    if (jobs.length === 0) return json(200, { sent: 0, devices: 0 });

    const accessToken = await googleAccessToken(sa);
    let sent = 0;
    let failed = 0;
    const invalid = new Set<string>();
    await inBatches(jobs, CONCURRENCY, async ({ n, d }) => {
      const outcome = await sendOne(sa, accessToken, d.device_token, n).catch(
        () => "failed" as const,
      );
      if (outcome === "sent") sent++;
      else if (outcome === "invalid_token") invalid.add(d.id);
      else failed++;
    });

    if (invalid.size > 0) {
      await admin
        .from("notification_devices")
        .update({ is_active: false })
        .in("id", [...invalid]);
    }
    return json(200, { sent, failed, deactivated: invalid.size });
  } catch (e) {
    // Never echo internals (could include provider responses).
    console.error("send-push failed:", e instanceof Error ? e.name : typeof e);
    return json(500, { error: "Push dispatch failed" });
  }
});
