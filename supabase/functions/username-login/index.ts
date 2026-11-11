import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
  "Vary": "Origin"
};

function respond(body: Record<string, unknown>, status: number, origin: string) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Access-Control-Allow-Origin": origin
    }
  });
}

function getCorsSettings(request: Request) {
  const configuredOrigins = (Deno.env.get("CORS_ALLOWED_ORIGINS") || Deno.env.get("CORS_ALLOWED_ORIGIN") || "*")
    .split(",")
    .map((origin) => origin.trim())
    .filter(Boolean);
  const allowedOrigins = new Set([
    ...configuredOrigins,
    "http://localhost:5173",
    "http://127.0.0.1:5173"
  ]);
  const requestOrigin = request.headers.get("origin") || "";
  const originAllowed = !requestOrigin || allowedOrigins.has("*") || allowedOrigins.has(requestOrigin);
  const allowOrigin = allowedOrigins.has("*")
    ? "*"
    : allowedOrigins.has(requestOrigin) ? requestOrigin : configuredOrigins[0] || "null";
  return { originAllowed, allowOrigin };
}

Deno.serve(async (request: Request) => {
  const { originAllowed, allowOrigin } = getCorsSettings(request);
  if (!originAllowed) {
    return respond({ error: "Origin is not allowed." }, 403, allowOrigin);
  }
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: { ...corsHeaders, "Access-Control-Allow-Origin": allowOrigin } });
  }
  if (request.method !== "POST") {
    return respond({ error: "Method not allowed." }, 405, allowOrigin);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    console.error("Required username login function environment variables are missing.");
    return respond({ error: "Username login is not configured." }, 500, allowOrigin);
  }

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return respond({ error: "Request body must be valid JSON." }, 400, allowOrigin);
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return respond({ error: "Request body must be an object." }, 400, allowOrigin);
  }

  const login = typeof body.username === "string" ? body.username.trim() : "";
  const password = typeof body.password === "string" ? body.password : "";
  const isEmail = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(login);
  const isUsername = login.length <= 120 && /^[\p{L}\p{N} .'-]+$/u.test(login);
  if ((!isEmail && !isUsername) || !password) {
    return respond({ error: "Enter a valid username or email and password." }, 400, allowOrigin);
  }

  try {
    const adminClient = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false }
    });
    const lookupColumn = isEmail ? "email" : "username";
    const { data: profile, error: profileError } = await adminClient
      .from("profiles")
      .select("email, role, status, freelancer_id")
      .ilike(lookupColumn, login.replace(/[\\%_]/g, "\\$&"))
      .maybeSingle();
    if (profileError) {
      console.error("Could not look up the username.", profileError);
      return respond({ error: "Could not complete the login request." }, 500, allowOrigin);
    }
    if (!profile || profile.status !== "active" ||
      !["client", "freelancer"].includes(profile.role) ||
      (profile.role === "freelancer" && !profile.freelancer_id)) {
      return respond({ error: "Invalid username or password." }, 401, allowOrigin);
    }

    const authClient = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false }
    });
    const { data, error } = await authClient.auth.signInWithPassword({
      email: profile.email,
      password
    });
    if (error || !data.session) {
      return respond({ error: "Invalid username or password." }, 401, allowOrigin);
    }

    return respond({ session: data.session }, 200, allowOrigin);
  } catch (error) {
    console.error("Username login request failed.", error);
    return respond({ error: "The login request could not be completed." }, 500, allowOrigin);
  }
});
