import { createClient } from "@/lib/supabase/server";
import type { Couple, Profile } from "@/types/database";

export interface CurrentUser {
  profile: Profile;
  couple: Couple | null;
  partner: Profile | null;
}

/**
 * Loads the current user's profile, their couple, and their partner's profile
 * (if any). Returns null when the user is not signed in or has no profile yet.
 *
 * Call from Server Components inside /app only.
 */
export async function getCurrentUser(): Promise<CurrentUser | null> {
  const supabase = createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) return null;

  const { data: profile } = await supabase
    .from("profiles")
    .select("*")
    .eq("id", user.id)
    .maybeSingle();

  if (!profile) return null;

  let couple: Couple | null = null;
  let partner: Profile | null = null;

  if (profile.couple_id) {
    const { data: coupleRow } = await supabase
      .from("couples")
      .select("*")
      .eq("id", profile.couple_id)
      .maybeSingle();

    couple = coupleRow;

    if (couple) {
      const { data: partnerRow } = await supabase
        .from("profiles")
        .select("*")
        .eq("couple_id", couple.id)
        .neq("id", profile.id)
        .maybeSingle();

      partner = partnerRow;
    }
  }

  return { profile, couple, partner };
}
