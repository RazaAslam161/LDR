"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import type { PresenceStatus } from "@/types/database";

export async function signOut() {
  const supabase = createClient();
  await supabase.auth.signOut();
  revalidatePath("/");
  redirect("/");
}

export async function setNextVisit(formData: FormData) {
  const supabase = createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "Not signed in." };

  const { data: profile } = await supabase
    .from("profiles")
    .select("couple_id")
    .eq("id", user.id)
    .maybeSingle();
  if (!profile?.couple_id) return { error: "Join a couple first." };

  const startDate = String(formData.get("startDate") ?? "");
  const location = String(formData.get("location") ?? "").trim();

  if (!startDate) return { error: "Pick a date for your next visit." };

  // Mark any prior upcoming visit as past, then insert the new one
  await supabase
    .from("visits")
    .update({ is_upcoming: false })
    .eq("couple_id", profile.couple_id)
    .eq("is_upcoming", true);

  const { error } = await supabase.from("visits").insert({
    couple_id: profile.couple_id,
    start_date: new Date(startDate).toISOString(),
    location: location || null,
    is_upcoming: true,
  });

  if (error) return { error: error.message };

  revalidatePath("/app");
  return { ok: true };
}


/**
 * Generates a short, human-friendly invite code like "MILES-4F2K".
 * Not cryptographically strong — just needs to be guess-resistant for a few days.
 */
function generateInviteCode(): string {
  const chars = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"; // no ambiguous chars
  let code = "";
  for (let i = 0; i < 4; i++) {
    code += chars[Math.floor(Math.random() * chars.length)];
  }
  return code;
}

export async function completeOnboarding(formData: FormData) {
  const supabase = createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "Not signed in." };

  const displayName = String(formData.get("displayName") ?? "").trim();
  const timezone = String(formData.get("timezone") ?? "").trim();
  const startNew = formData.get("startNew") === "true";

  if (!displayName) return { error: "Please tell us your name." };
  if (!timezone) return { error: "Please pick your timezone." };

  // 1. Ensure a profile row exists
  const { data: existing } = await supabase
    .from("profiles")
    .select("id, couple_id")
    .eq("id", user.id)
    .maybeSingle();

  if (!existing) {
    const { error: profileErr } = await supabase.from("profiles").insert({
      id: user.id,
      display_name: displayName,
      timezone,
      presence_status: "free" satisfies PresenceStatus,
    });
    if (profileErr) return { error: profileErr.message };
  } else {
    await supabase
      .from("profiles")
      .update({ display_name: displayName, timezone })
      .eq("id", user.id);
  }

  // 2. Start a new couple (creator side) → produce an invite code
  if (startNew) {
    let inviteCode = "";
    let attempts = 0;
    do {
      inviteCode = generateInviteCode();
      const { data: clash } = await supabase
        .from("couples")
        .select("id")
        .eq("invite_code", inviteCode)
        .maybeSingle();
      if (!clash) break;
      attempts++;
    } while (attempts < 5);

    const { data: couple, error: coupleErr } = await supabase
      .from("couples")
      .insert({
        invite_code: inviteCode,
        primary_tz: timezone,
      })
      .select()
      .single();

    if (coupleErr || !couple) return { error: coupleErr?.message ?? "Could not create couple." };

    await supabase
      .from("profiles")
      .update({ couple_id: couple.id })
      .eq("id", user.id);

    revalidatePath("/couple");
    return { inviteCode, coupleId: couple.id };
  }

  // 3. Otherwise just persist the profile and let the /couple page take over
  revalidatePath("/couple");
  return {};
}

export async function joinCouple(formData: FormData) {
  const supabase = createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "Not signed in." };

  const rawCode = String(formData.get("inviteCode") ?? "")
    .trim()
    .toUpperCase()
    .replace(/\s+/g, "");

  if (!rawCode) return { error: "Enter the invite code your partner shared." };

  const { data: couple, error } = await supabase
    .from("couples")
    .select("id")
    .eq("invite_code", rawCode)
    .maybeSingle();

  if (error || !couple) {
    return { error: "We couldn't find that code. Double-check with your partner." };
  }

  // Make sure this couple isn't already full (max 2 partners)
  const { count } = await supabase
    .from("profiles")
    .select("id", { count: "exact", head: true })
    .eq("couple_id", couple.id);

  if ((count ?? 0) >= 2) {
    return { error: "This couple already has two members." };
  }

  await supabase.from("profiles").update({ couple_id: couple.id }).eq("id", user.id);

  revalidatePath("/app");
  return { ok: true };
}
