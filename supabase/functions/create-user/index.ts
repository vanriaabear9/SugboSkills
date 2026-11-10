import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
  "Vary": "Origin"
};

const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function respond(body: Record<string, unknown>, status: number, origin: string) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Access-Control-Allow-Origin": origin
    }
  });
}

function defaultFreelancerPassword(name: string) {
  const password = name.normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/[^a-z0-9]/g, "");
  return `${password}1`;
}

function freelancerEmailAlias(name: string) {
  return name.normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/[^a-z0-9]/g, "");
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
    if (action === "provisionRoster") {
      const { data: roster, error: rosterError } = await adminClient
        .from("prototype_freelancers")
        .select("id, name, skill, level")
        .order("sort_order");
      if (rosterError) {
        console.error("Could not load the freelancer roster.", rosterError);
        return respond({ error: "Could not load the freelancer roster. Apply the real freelancer accounts migration first." }, 500, allowOrigin);
      }

      const { data: profiles, error: profilesError } = await adminClient
        .from("profiles")
        .select("id, username, freelancer_id, role, status");
      if (profilesError) {
        console.error("Could not check existing freelancer accounts.", profilesError);
        return respond({ error: "Could not check existing accounts. Apply the real freelancer accounts migration first." }, 500, allowOrigin);
      }

      const profilesByRosterId = new Map(
        profiles.filter((profile) => profile.freelancer_id).map((profile) => [profile.freelancer_id, profile])
      );
      const usedUsernames = new Map(
        profiles.map((profile) => [String(profile.username || "").toLowerCase(), profile.id])
      );
      const generatedPasswords = new Set<string>();
      for (const freelancer of roster) {
        const name = String(freelancer.name).trim();
        const username = `${freelancerEmailAlias(name)}@gmail.com`;
        const password = defaultFreelancerPassword(name);
        const linkedProfile = profilesByRosterId.get(freelancer.id);
        const conflictingProfileId = usedUsernames.get(username.toLowerCase());
        if (!name || name.length > 120 ||
          (usedUsernames.has(username.toLowerCase()) && conflictingProfileId !== linkedProfile?.id)) {
          return respond({ error: `Cannot provision ${name || "a roster account"} because its username is invalid or already taken.` }, 409, allowOrigin);
        }
        if (linkedProfile && linkedProfile.role !== "freelancer") {
          return respond({ error: `Cannot update ${name}: its linked account is not a freelancer account.` }, 409, allowOrigin);
        }
        if (!freelancerEmailAlias(name) || freelancerEmailAlias(name).length > 64 ||
          password.length < 8 || password.length > 72 || generatedPasswords.has(password)) {
          return respond({ error: `Cannot provision ${name}: its email alias or generated password is invalid or not unique.` }, 409, allowOrigin);
        }
        usedUsernames.set(username.toLowerCase(), linkedProfile?.id || "");
        generatedPasswords.add(password);
      }

      const createdUserIds: string[] = [];
      const credentials: Array<{ name: string; username: string; password: string }> = [];
      try {
        for (const freelancer of roster) {
          const name = String(freelancer.name).trim();
          const username = `${freelancerEmailAlias(name)}@gmail.com`;
          const password = defaultFreelancerPassword(name);
          const internalEmail = `${freelancerEmailAlias(name)}@login.sugboskills.invalid`;
          const linkedProfile = profilesByRosterId.get(freelancer.id);
          let userId: string;
          if (linkedProfile) {
            const { data: updated, error: updateError } = await adminClient.auth.admin.updateUserById(linkedProfile.id, {
              email: internalEmail,
              password,
              email_confirm: true,
              user_metadata: { full_name: name, username }
            });
            if (updateError || !updated.user) {
              throw new Error(updateError?.message || `Supabase did not return the updated account for ${name}.`);
            }
            userId = updated.user.id;
          } else {
            const { data: created, error: createError } = await adminClient.auth.admin.createUser({
              email: internalEmail,
              password,
              email_confirm: true,
              user_metadata: { full_name: name, username }
            });
            if (createError || !created.user) {
              throw new Error(createError?.message || `Supabase did not return the account for ${name}.`);
            }
            userId = created.user.id;
            createdUserIds.push(userId);
          }

          const { error: profileError } = await adminClient.from("profiles").upsert({
            id: userId,
            full_name: name,
            username,
            email: internalEmail,
            freelancer_id: freelancer.id,
            role: "freelancer",
            skill: freelancer.skill,
            level: String(freelancer.level).toLowerCase(),
            status: linkedProfile?.status || "active"
          }, { onConflict: "id" });
          if (profileError) throw new Error(`Could not save the profile for ${name}: ${profileError.message}`);
          credentials.push({ name, username, password });
        }
      } catch (error) {
        for (const userId of createdUserIds.reverse()) {
          const { error: cleanupError } = await adminClient.auth.admin.deleteUser(userId);
          if (cleanupError) console.error("Could not remove a partially provisioned roster account.", cleanupError);
        }
        console.error("Could not provision the freelancer roster.", error);
        return respond({ error: "Freelancer account setup failed. Newly created accounts were rolled back where possible; retry to apply the password format to any existing accounts already updated." }, 500, allowOrigin);
      }

      return respond({
        message: `Set up ${credentials.length} freelancer accounts with the required usernames and passwords. Copy and share these credentials securely.`,
        credentials
      }, 200, allowOrigin);
    }

    if (action === "create") {
      const fullName = typeof body.fullName === "string" ? body.fullName.trim() : "";
      const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
      const role = body.role;
      if (!fullName || fullName.length > 120 || !emailPattern.test(email) || email.length > 254) {
        return respond({ error: "Enter a full name and a valid email address." }, 400, allowOrigin);
      }
      if (role !== "admin") {
        return respond({ error: "Only admin invites can be sent by email. Freelancer roster accounts use username and password." }, 400, allowOrigin);
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
        .select("email, role, status")
        .eq("id", userId)
        .maybeSingle();
      if (profileError) return respond({ error: "Could not find that account." }, 404, allowOrigin);
      if (!profile || profile.status !== "active") {
        return respond({ error: "Only active accounts can receive a new invite." }, 400, allowOrigin);
      }
      if (profile.role === "freelancer") {
        return respond({ error: "Freelancer accounts use a username and password and do not receive email invites." }, 400, allowOrigin);
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
