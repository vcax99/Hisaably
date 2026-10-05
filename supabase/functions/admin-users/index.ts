// Hisaably — admin-users Edge Function (Super Admin user management)
//
// Actions (POST JSON { action, ... }):
//   create_user     { name, username, password }
//   reset_password  { user_id, password }
//   disable_user    { user_id }   -> profile DISABLED + Auth ban (login fails)
//   enable_user     { user_id }
//   delete_user     { user_id }   -> Auth user deleted; profile/memberships cascade
//
// Why an Edge Function: these need the Supabase Auth admin API, i.e. the
// service-role key, which must never ship in the app. The key is injected by
// Supabase into this function's environment only.
//
// Every call verifies the caller's access token with Supabase Auth and then
// checks the caller is an ACTIVE SUPER_ADMIN in `profiles`. The client's
// claims about its own role are never trusted.

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

const USERNAME_RE = /^[a-z0-9]([a-z0-9._]{1,28})[a-z0-9]$/;
const EMAIL_DOMAIN = "users.hisaably.invalid";
const BAN_FOREVER = "876000h"; // ~100 years
const MIN_PASSWORD = 8;
const MAX_PASSWORD = 72; // bcrypt limit

class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

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

async function requireSuperAdmin(
  admin: SupabaseClient,
  req: Request,
): Promise<string> {
  const header = req.headers.get("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!token) throw new HttpError(401, "NOT_AUTHENTICATED", "Please sign in again.");

  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) {
    throw new HttpError(401, "NOT_AUTHENTICATED", "Please sign in again.");
  }

  const { data: profile, error: profileError } = await admin
    .from("profiles")
    .select("role, status")
    .eq("id", data.user.id)
    .maybeSingle();
  if (profileError) throw profileError;
  if (!profile || profile.status !== "ACTIVE") {
    throw new HttpError(403, "ACCOUNT_DISABLED", "Your account has been disabled.");
  }
  if (profile.role !== "SUPER_ADMIN") {
    throw new HttpError(403, "FORBIDDEN", "Only the Super Admin can manage users.");
  }
  return data.user.id;
}

function requireString(body: Record<string, unknown>, key: string): string {
  const value = body[key];
  if (typeof value !== "string") {
    throw new HttpError(400, "VALIDATION", `Missing ${key}.`);
  }
  return value;
}

function validatePassword(password: string): string {
  if (password.length < MIN_PASSWORD) {
    throw new HttpError(400, "VALIDATION", `Password must be at least ${MIN_PASSWORD} characters.`);
  }
  if (password.length > MAX_PASSWORD) {
    throw new HttpError(400, "VALIDATION", `Password must be at most ${MAX_PASSWORD} characters.`);
  }
  return password;
}

function validateName(raw: string): string {
  const name = raw.trim().replace(/\s+/g, " ");
  if (name.length < 1 || name.length > 80) {
    throw new HttpError(400, "VALIDATION", "Name must be 1–80 characters.");
  }
  return name;
}

function validateUsername(raw: string): string {
  const username = raw.trim().toLowerCase();
  if (!USERNAME_RE.test(username)) {
    throw new HttpError(
      400,
      "VALIDATION",
      "Username must be 3–30 characters: lowercase letters, numbers, and . or _ in the middle.",
    );
  }
  return username;
}

async function requireTarget(
  admin: SupabaseClient,
  body: Record<string, unknown>,
  callerId: string,
  { allowSelf }: { allowSelf: boolean },
): Promise<string> {
  const userId = requireString(body, "user_id");
  if (!allowSelf && userId === callerId) {
    throw new HttpError(403, "FORBIDDEN", "You cannot do this to your own account.");
  }
  const { data, error } = await admin
    .from("profiles")
    .select("id")
    .eq("id", userId)
    .maybeSingle();
  if (error) throw error;
  if (!data) throw new HttpError(404, "NOT_FOUND", "User not found.");
  return userId;
}

async function createUser(admin: SupabaseClient, body: Record<string, unknown>) {
  const name = validateName(requireString(body, "name"));
  const username = validateUsername(requireString(body, "username"));
  const password = validatePassword(requireString(body, "password"));

  const { data: existing, error: lookupError } = await admin
    .from("profiles")
    .select("id")
    .eq("username", username)
    .maybeSingle();
  if (lookupError) throw lookupError;
  if (existing) {
    throw new HttpError(409, "USERNAME_TAKEN", "This username is already taken.");
  }

  const { data, error } = await admin.auth.admin.createUser({
    email: `${username}@${EMAIL_DOMAIN}`,
    password,
    email_confirm: true,
    user_metadata: { username, name },
  });
  if (error || !data.user) {
    const message = error?.message ?? "";
    if (/already|exists|registered/i.test(message)) {
      throw new HttpError(409, "USERNAME_TAKEN", "This username is already taken.");
    }
    if (/password/i.test(message)) {
      throw new HttpError(400, "VALIDATION", "Password is too weak.");
    }
    throw error ?? new Error("createUser returned no user");
  }

  const { data: profile, error: profileError } = await admin
    .from("profiles")
    .select("id, name, username, role, status, created_at")
    .eq("id", data.user.id)
    .single();
  if (profileError) throw profileError;
  return { user: profile };
}

async function resetPassword(admin: SupabaseClient, userId: string, body: Record<string, unknown>) {
  const password = validatePassword(requireString(body, "password"));
  const { error } = await admin.auth.admin.updateUserById(userId, { password });
  if (error) {
    if (/password/i.test(error.message)) {
      throw new HttpError(400, "VALIDATION", "Password is too weak.");
    }
    throw error;
  }
  return {};
}

async function setDisabled(admin: SupabaseClient, userId: string, disabled: boolean) {
  // Ban first so a failure never leaves a "DISABLED" profile that can still log in.
  const { error } = await admin.auth.admin.updateUserById(userId, {
    ban_duration: disabled ? BAN_FOREVER : "none",
  });
  if (error) throw error;

  const { error: profileError } = await admin
    .from("profiles")
    .update({ status: disabled ? "DISABLED" : "ACTIVE" })
    .eq("id", userId);
  if (profileError) throw profileError;
  return {};
}

async function deleteUser(admin: SupabaseClient, userId: string) {
  const { error } = await admin.auth.admin.deleteUser(userId);
  if (error) throw error;
  return {};
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json(405, { error: { code: "METHOD_NOT_ALLOWED", message: "Use POST." } });
  }

  try {
    const admin = serviceClient();
    const callerId = await requireSuperAdmin(admin, req);

    let body: Record<string, unknown>;
    try {
      body = await req.json();
    } catch {
      throw new HttpError(400, "VALIDATION", "Invalid request body.");
    }

    let result: Record<string, unknown>;
    switch (body.action) {
      case "create_user":
        result = await createUser(admin, body);
        break;
      case "reset_password":
        result = await resetPassword(
          admin,
          await requireTarget(admin, body, callerId, { allowSelf: true }),
          body,
        );
        break;
      case "disable_user":
        result = await setDisabled(
          admin,
          await requireTarget(admin, body, callerId, { allowSelf: false }),
          true,
        );
        break;
      case "enable_user":
        result = await setDisabled(
          admin,
          await requireTarget(admin, body, callerId, { allowSelf: false }),
          false,
        );
        break;
      case "delete_user":
        result = await deleteUser(
          admin,
          await requireTarget(admin, body, callerId, { allowSelf: false }),
        );
        break;
      default:
        throw new HttpError(400, "VALIDATION", "Unknown action.");
    }

    return json(200, { ok: true, ...result });
  } catch (e) {
    if (e instanceof HttpError) {
      return json(e.status, { error: { code: e.code, message: e.message } });
    }
    // Log the technical reason server-side only; never tokens or passwords.
    console.error("admin-users failed:", e instanceof Error ? e.message : String(e));
    return json(500, {
      error: { code: "UNEXPECTED", message: "Something went wrong. Please try again." },
    });
  }
});
