"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { completeOnboarding } from "@/app/actions";

const COMMON_TIMEZONES = [
  "America/Los_Angeles",
  "America/Denver",
  "America/Chicago",
  "America/New_York",
  "America/Sao_Paulo",
  "Europe/London",
  "Europe/Berlin",
  "Europe/Paris",
  "Europe/Istanbul",
  "Asia/Dubai",
  "Asia/Karachi",
  "Asia/Kolkata",
  "Asia/Dhaka",
  "Asia/Singapore",
  "Asia/Tokyo",
  "Australia/Sydney",
  "Pacific/Auckland",
];

export default function WelcomePage() {
  const router = useRouter();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [inviteCode, setInviteCode] = useState<string | null>(null);

  // Default to the browser's timezone if we recognise it
  const detected =
    typeof Intl !== "undefined"
      ? Intl.DateTimeFormat().resolvedOptions().timeZone
      : "America/New_York";

  async function handleSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError(null);
    setLoading(true);

    const formData = new FormData(e.currentTarget);
    const res = await completeOnboarding(formData);

    if (res?.error) {
      setError(res.error);
      setLoading(false);
      return;
    }

    if (res?.inviteCode) {
      setInviteCode(res.inviteCode);
      setLoading(false);
    } else {
      router.push("/couple");
      router.refresh();
    }
  }

  if (inviteCode) {
    return (
      <main className="flex min-h-screen items-center justify-center px-6 py-16">
        <div className="w-full max-w-md text-center">
          <p className="mb-6 text-sm uppercase tracking-[0.2em] text-coral-400">
            You&rsquo;re in
          </p>
          <h1 className="font-display text-3xl text-cream-50">
            Share this with your person
          </h1>
          <p className="mt-3 text-sm text-cream-100/60">
            They&rsquo;ll sign up with the code below. Once they join, your
            countdown begins.
          </p>

          <div className="my-10">
            <div className="rounded-3xl border border-dashed border-coral-400/40 bg-coral-500/5 p-8">
              <p className="text-xs uppercase tracking-widest text-cream-100/40">
                Your invite code
              </p>
              <p className="mt-3 font-display text-5xl tracking-[0.15em] text-cream-50 tabular-nums">
                {inviteCode}
              </p>
            </div>
            <p className="mt-4 text-xs text-cream-100/40">
              Send it over text, WhatsApp, whatever you use. It doesn&rsquo;t
              expire.
            </p>
          </div>

          <button
            onClick={() => {
              navigator.clipboard?.writeText(inviteCode);
            }}
            className="btn-secondary mr-2"
          >
            Copy code
          </button>
          <button onClick={() => router.push("/couple")} className="btn-primary">
            I&rsquo;ll wait here
          </button>
        </div>
      </main>
    );
  }

  return (
    <main className="flex min-h-screen items-center justify-center px-6 py-16">
      <div className="w-full max-w-sm">
        <h1 className="font-display text-3xl text-cream-50">A little about you</h1>
        <p className="mt-2 text-sm text-cream-100/60">
          We&rsquo;ll use this to set up your space.
        </p>

        <form onSubmit={handleSubmit} className="mt-8 space-y-4">
          <input type="hidden" name="startNew" value="true" />

          <div>
            <label className="mb-1.5 block text-xs text-cream-100/50">
              Your name
            </label>
            <input
              name="displayName"
              required
              className="input"
              placeholder="What should we call you?"
            />
          </div>

          <div>
            <label className="mb-1.5 block text-xs text-cream-100/50">
              Your timezone
            </label>
            <select name="timezone" defaultValue={detected} className="input">
              {COMMON_TIMEZONES.map((tz) => (
                <option key={tz} value={tz} className="bg-navy-900">
                  {tz.replace(/_/g, " ")}
                </option>
              ))}
            </select>
            <p className="mt-1.5 text-xs text-cream-100/40">
              Detected: {detected.replace(/_/g, " ")}
            </p>
          </div>

          {error && (
            <p className="rounded-xl bg-coral-500/10 px-4 py-3 text-sm text-coral-400">
              {error}
            </p>
          )}

          <button type="submit" disabled={loading} className="btn-primary w-full">
            {loading ? "Setting up…" : "Create our space"}
          </button>
        </form>
      </div>
    </main>
  );
}
