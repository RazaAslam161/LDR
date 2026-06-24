import { getCurrentUser } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { Countdown } from "@/components/Countdown";
import { SetVisitForm } from "@/components/SetVisitForm";
import type { Visit } from "@/types/database";

export default async function HomePage() {
  const user = await getCurrentUser();
  const supabase = createClient();

  const { data: upcoming } = await supabase
    .from("visits")
    .select("*")
    .eq("couple_id", user!.couple!.id)
    .eq("is_upcoming", true)
    .order("start_date", { ascending: true })
    .limit(1)
    .maybeSingle();

  const visit: Visit | null = upcoming;

  return (
    <div className="mx-auto max-w-4xl">
      {visit ? (
        <div className="flex min-h-[70vh] flex-col items-center justify-center">
          <p className="mb-12 text-sm uppercase tracking-[0.2em] text-coral-400">
            {visit.location ? `Next visit · ${visit.location}` : "Next visit"}
          </p>

          <Countdown
            targetDate={visit.start_date}
            partnerTimezone={user!.partner?.timezone ?? user!.profile.timezone}
          />

          <p className="mt-16 text-sm text-cream-100/40">
            {new Date(visit.start_date).toLocaleDateString(undefined, {
              weekday: "long",
              year: "numeric",
              month: "long",
              day: "numeric",
            })}
          </p>
        </div>
      ) : (
        <div className="flex min-h-[70vh] flex-col items-center justify-center text-center">
          <p className="mb-4 text-4xl">✈️</p>
          <h1 className="font-display text-4xl text-cream-50 sm:text-5xl">
            When&rsquo;s your next visit?
          </h1>
          <p className="mt-4 max-w-sm text-sm text-cream-100/60">
            Set a date — even a tentative one. The countdown is the heartbeat of
            this space.
          </p>

          <div className="mt-10 w-full max-w-sm">
            <SetVisitForm />
          </div>
        </div>
      )}
    </div>
  );
}
