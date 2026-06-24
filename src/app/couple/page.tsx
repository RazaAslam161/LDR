"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { joinCouple } from "@/app/actions";

export default function CouplePage() {
  const router = useRouter();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [code, setCode] = useState("");

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);

    const formData = new FormData();
    formData.set("inviteCode", code);

    const res = await joinCouple(formData);
    if (res?.error) {
      setError(res.error);
      setLoading(false);
      return;
    }

    router.push("/app");
    router.refresh();
  }

  return (
    <main className="flex min-h-screen items-center justify-center px-6 py-16">
      <div className="w-full max-w-sm">
        <h1 className="font-display text-3xl text-cream-50">Join your partner</h1>
        <p className="mt-2 text-sm text-cream-100/60">
          Enter the code they shared with you.
        </p>

        <form onSubmit={handleSubmit} className="mt-8 space-y-4">
          <div>
            <label className="mb-1.5 block text-xs text-cream-100/50">
              Invite code
            </label>
            <input
              required
              value={code}
              onChange={(e) => setCode(e.target.value.toUpperCase())}
              className="input text-center font-display text-2xl tracking-[0.2em] tabular-nums"
              placeholder="XXXX"
              maxLength={8}
            />
          </div>

          {error && (
            <p className="rounded-xl bg-coral-500/10 px-4 py-3 text-sm text-coral-400">
              {error}
            </p>
          )}

          <button type="submit" disabled={loading} className="btn-primary w-full">
            {loading ? "Joining…" : "Join"}
          </button>
        </form>
      </div>
    </main>
  );
}
