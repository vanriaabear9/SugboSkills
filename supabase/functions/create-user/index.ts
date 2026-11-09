import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json"
};

const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const allowedSkills = new Set([
  "graphic design",
  "video editing",
  "photo editing",
  "web development",
  "CAD 3D modeling"
]);
const allowedLevels = new Set(["intermediate", "advanced"]);

function respond(body: Record<string, unknown>, status: number, origin: string) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Access-Control-Allow-Origin": origin
    }
  });
}

Deno.serve(async (request: Request) => {
  const configuredOrigin = Deno.env.get("CORS_ALLOWED_ORIGIN") || "*";
  const allowOrigin = configuredOrigin === "*" ? "*" : configuredOrigin;

  if (configuredOrigin !== "*" && request.headers.get("origin") && request.headers.get("origin") !== configuredOrigin) {
    return respond({ error: "Origin is not allowed." }, 403, allowOrigin);
  }
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: { ...corsHeaders, "Access-Control-Allow-Origin": allowOrigin } });
  }
  if (request.method !== "POST") {
    return respond({ error: "Method not allowed." }, 405, allowOrigin);
  }

  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) {
    return respond({ error: "A valid user session is required." }, 401, allowOrigin);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    console.error("Required Supabase function environment variables are missing.");
    return respond({ error: "The account service is not configured." }, 500, allowOrigin);
  }

  try {
    const callerClient = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: authorization } }
    });
    const { data: userResult, error: tokenError } = await callerClient.auth.getUser();
    if (tokenError || !userResult.user) {
      return respond({ error: "The login session is invalid or expired." }, 401, allowOrigin);
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false }
    });
    const { data: callerProfile, error: callerProfileError } = await adminClient
      .from("profiles")
      .select("role, status")
      .eq("id", userResult.user.id)
      .maybeSingle();
    if (callerProfileError) {
      console.error("Could not verify the caller's profile.", callerProfileError);
      return respond({ error: "Could not verify your account permissions." }, 500, allowOrigin);
    }
    if (callerProfile?.role !== "admin" || callerProfile.status !== "active") {
      return respond({ error: "Only an active admin can manage accounts." }, 403, allowOrigin);
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

    const action = body.action;
    if (action === "create") {
      const fullName = typeof body.fullName === "string" ? body.fullName.trim() : "";
      const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
      const role = body.role;
      if (!fullName || fullName.length > 120 || !emailPattern.test(email) || email.length > 254) {
        return respond({ error: "Enter a full name and a valid email address." }, 400, allowOrigin);
      }
      if (role !== "admin" && role !== "freelancer") {
        return respond({ error: "Only admin or freelancer accounts can be created here." }, 400, allowOrigin);
      }

      const skill = body.skill;
      const level = body.level;
      const team = body.team;
      if (role === "freelancer" && (
        typeof skill !== "string" || !allowedSkills.has(skill)
        || typeof level !== "string" || !allowedLevels.has(level)
        || (team !== "A" && team !== "B")
      )) {
        return respond({ error: "Select an allowed freelancer skill, level, and team." }, 400, allowOrigin);
      }

      const siteUrl = Deno.env.get("SITE_URL");
      if (!siteUrl) {
        return respond({ error: "SITE_URL is missing from the function environment." }, 500, allowOrigin);
      }
      const redirectTo = `${siteUrl.replace(/\/+$/, "")}/?setup=1`;
      const { data: invitation, error: inviteError } = await adminClient.auth.admin.inviteUserByEmail(email, {
        data: { full_name: fullName },
        redirectTo
      });
      if (inviteError || !invitation.user) {
        return respond({ error: inviteError?.message || "Supabase did not return the invited user." }, 400, allowOrigin);
      }

      const { error: profileError } = await adminClient.from("profiles").upsert({
        id: invitation.user.id,
        full_name: fullName,
        email,
        role,
        skill: role === "freelancer" ? skill : null,
        level: role === "freelancer" ? level : null,
        team: role === "freelancer" ? team : null,
        status: "active"
      }, { onConflict: "id" });
      if (profileError) {
        console.error("Invite was created but the profile update failed.", profileError);
        const { error: cleanupError } = await adminClient.auth.admin.deleteUser(invitation.user.id);
        if (cleanupError) console.error("Could not remove the incomplete invited account.", cleanupError);
        return respond({ error: "The invite was created, but the profile could not be saved." }, 500, allowOrigin);
      }
      return respond({ message: `Invite sent to ${email}.` }, 200, allowOrigin);
    }

    if (action === "resend") {
      const userId = typeof body.userId === "string" ? body.userId : "";
      if (!userId) return respond({ error: "A user ID is required." }, 400, allowOrigin);
      const { data: profile, error: profileError } = await adminClient
        .from("profiles")
        .select("email, status")
        .eq("id", userId)
        .maybeSingle();
      if (profileError) return respond({ error: "Could not find that account." }, 404, allowOrigin);
      if (!profile || profile.status !== "active") {
        return respond({ error: "Only active accounts can receive a new invite." }, 400, allowOrigin);
      }
      const siteUrl = Deno.env.get("SITE_URL");
      if (!siteUrl) return respond({ error: "SITE_URL is missing from the function environment." }, 500, allowOrigin);
      const { error: resendError } = await adminClient.auth.resend({
        type: "signup",
        email: profile.email,
        options: { emailRedirectTo: `${siteUrl.replace(/\/+$/, "")}/?setup=1` }
      });
      if (resendError) return respond({ error: resendError.message }, 400, allowOrigin);
      return respond({ message: `Account setup email resent to ${profile.email}.` }, 200, allowOrigin);
    }

    if (action === "deactivate" || action === "activate") {
      const userId = typeof body.userId === "string" ? body.userId : "";
      if (!userId) return respond({ error: "A user ID is required." }, 400, allowOrigin);
      if (userId === userResult.user.id) {
        return respond({ error: "You cannot deactivate or reactivate your own account here." }, 400, allowOrigin);
      }
      const { data: profile, error: profileLookupError } = await adminClient
        .from("profiles")
        .select("id")
        .eq("id", userId)
        .maybeSingle();
      if (profileLookupError || !profile) return respond({ error: "Could not find that account." }, 404, allowOrigin);

      const status = action === "deactivate" ? "inactive" : "active";
      const { error: authUpdateError } = await adminClient.auth.admin.updateUserById(userId, {
        ban_duration: action === "deactivate" ? "876000h" : "none"
      });
      if (authUpdateError) return respond({ error: authUpdateError.message }, 400, allowOrigin);
      const { error: statusError } = await adminClient.from("profiles").update({ status }).eq("id", userId);
      if (statusError) {
        console.error("Auth ban status changed but the profile status did not update.", statusError);
        return respond({ error: "The auth status changed, but the profile status could not be saved." }, 500, allowOrigin);
      }
      return respond({ message: `Account ${status}.` }, 200, allowOrigin);
    }

    return respond({ error: "Unsupported account action." }, 400, allowOrigin);
  } catch (error) {
    console.error("Account management request failed.", error);
    return respond({ error: "The account request could not be completed." }, 500, allowOrigin);
  }
});
