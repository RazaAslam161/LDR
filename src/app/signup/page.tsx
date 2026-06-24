"use client";

import { useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";

export default function SignupPage() {
  const router = useRouter();
  const params = useSearchParams();
  const redirect = params.get("redirect") ?? "/welcome";

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setNotice(null);
    setLoading(true);

    const supabase = createClient();
    const { error } = await supabase.auth.signUp({
      email,
      password,
      options: {
        emailRedirectTo: `${window.location.origin}/auth/callback?redirect=${encodeURIComponent(redirect)}`,
      },
    });

    if (error) {
      setError(error.message);
      setLoading(false);
      return;
    }

    setNotice("Check your inbox — we sent you a confirmation link.");
    setLoading(false);
  }

  async function handleGoogle() {
    setError(null);
    const supabase = createClient();
    const { error } = await supabase.auth.signInWithOAuth({
      provider: "google",
      options: {
        redirectTo: `${window.location.origin}/auth/callback?redirect=${encodeURIComponent(redirect)}`,
      },
    });
    if (error) setError(error.message);
  }

  return (
    <main className="flex min-h-screen items-center justify-center px-6 py-16">
      <div className="w-full max-w-sm">
        <Link
          href="/"
          className="mb-10 flex items-center gap-2 text-sm text-cream-100/50 transition hover:text-cream-50"
        >
          ← Back home
        </Link>

        <h1 className="font-display text-3xl text-cream-50">Begin</h1>
        <p className="mt-2 text-sm text-cream-100/60">
          Create your account. Invite your partner next.
        </p>

        <form onSubmit={handleSubmit} className="mt-8 space-y-4">
          <div>
            <label className="mb-1.5 block text-xs text-cream-100/50">
              Email
            </label>
            <input
              type="email"
              required
              autoComplete="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="input"
              placeholder="you@home.com"
            />
          </div>
          <div>
            <label className="mb-1.5 block text-xs text-cream-100/50">
              Password
            </label>
            <input
              type="password"
              required
              minLength={8}
              autoComplete="new-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="input"
              placeholder="At least 8 characters"
            />
          </div>

          {error && (
            <p className="rounded-xl bg-coral-500/10 px-4 py-3 text-sm text-coral-400">
              {error}
            </p>
          )}
          {notice && (
            <p className="rounded-xl bg-cream-50/5 px-4 py-3 text-sm text-cream-100/80">
              {notice}
            </p>
          )}

          <button type="submit" disabled={loading} className="btn-primary w-full">
            {loading ? "Creating…" : "Create account"}
          </button>
        </form>

        <div className="my-6 flex items-center gap-4">
          <div className="h-px flex-1 bg-cream-100/10" />
          <span className="text-xs text-cream-100/40">or</span>
          <div className="h-px flex-1 bg-cream-100/10" />
        </div>

        <button onClick={handleGoogle} className="btn-secondary w-full">
          Continue with Google
        </button>

        <p className="mt-8 text-center text-sm text-cream-100/60">
          Already with us?{" "}
          <Link href="/login" className="text-coral-400 hover:text-coral-500">
            Sign in
          </Link>
        </p>
      </div>
    </main>
  );
}
