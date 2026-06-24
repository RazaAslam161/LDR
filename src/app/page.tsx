import Link from "next/link";

export default function LandingPage() {
  return (
    <main className="relative min-h-screen overflow-hidden">
      {/* Nav */}
      <nav className="mx-auto flex max-w-6xl items-center justify-between px-6 py-6">
        <div className="flex items-center gap-2">
          <div className="h-2 w-2 rounded-full bg-coral-500 animate-pulse-soft" />
          <span className="font-serif text-lg">Miles</span>
        </div>
        <div className="flex items-center gap-3">
          <Link
            href="/login"
            className="px-4 py-2 text-sm text-cream-100/70 transition hover:text-cream-50"
          >
            Sign in
          </Link>
          <Link href="/signup" className="btn-primary">
            Start together
          </Link>
        </div>
      </nav>

      {/* Hero */}
      <section className="mx-auto max-w-4xl px-6 pt-20 pb-32 text-center">
        <p className="mb-6 text-sm uppercase tracking-[0.2em] text-coral-400">
          For couples apart
        </p>
        <h1 className="font-display text-5xl font-light leading-[1.05] tracking-tight text-cream-50 sm:text-7xl">
          Feel close,
          <br />
          <span className="text-gradient italic">even from here.</span>
        </h1>
        <p className="mx-auto mt-8 max-w-xl text-lg leading-relaxed text-cream-100/70">
          Not another couples app. Miles is built around the experience of
          distance — the countdown, the timezones, the small rituals that make
          it bearable.
        </p>
        <div className="mt-10 flex flex-col items-center justify-center gap-3 sm:flex-row">
          <Link href="/signup" className="btn-primary w-full sm:w-auto">
            Start your countdown
          </Link>
          <Link href="#how" className="btn-secondary w-full sm:w-auto">
            See how it works
          </Link>
        </div>
        <p className="mt-6 text-xs text-cream-100/40">
          Free forever. Together plan from $39/year — less than a single date
          night.
        </p>
      </section>

      {/* How it works */}
      <section
        id="how"
        className="mx-auto max-w-5xl px-6 pb-32"
      >
        <div className="grid gap-6 md:grid-cols-3">
          {[
            {
              emoji: "⏰",
              title: "The countdown",
              body: "A live, beautiful countdown to your next visit. It's the first thing you see, every day.",
            },
            {
              emoji: "🌍",
              title: "Timezone rituals",
              body: "Send a goodnight that arrives at their evening. Be present at the right moment, even when the hours don't align.",
            },
            {
              emoji: "📅",
              title: "The journey",
              body: "Every reunion logged. Every stretch apart measured. Watch the distance shrink over time.",
            },
          ].map((f) => (
            <div key={f.title} className="card p-7">
              <div className="mb-4 text-3xl">{f.emoji}</div>
              <h3 className="mb-2 font-display text-xl text-cream-50">
                {f.title}
              </h3>
              <p className="text-sm leading-relaxed text-cream-100/60">
                {f.body}
              </p>
            </div>
          ))}
        </div>
      </section>

      {/* Quote / emotional hook */}
      <section className="mx-auto max-w-3xl px-6 pb-32 text-center">
        <blockquote className="font-display text-2xl font-light italic leading-relaxed text-cream-100/80 sm:text-3xl">
          &ldquo;Distance is just a test to see how far love can travel.&rdquo;
        </blockquote>
      </section>

      {/* Footer CTA */}
      <section className="mx-auto max-w-3xl px-6 pb-32 text-center">
        <h2 className="font-display text-3xl text-cream-50 sm:text-4xl">
          Start closing the distance.
        </h2>
        <p className="mt-4 text-cream-100/60">
          Set your next visit date in under 2 minutes.
        </p>
        <Link href="/signup" className="btn-primary mt-8">
          Begin
        </Link>
      </section>

      <footer className="border-t border-cream-100/5 py-8">
        <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-4 px-6 text-xs text-cream-100/40 sm:flex-row">
          <span>© {new Date().getFullYear()} Miles. Made for the apart.</span>
          <span>Your data stays yours. Always.</span>
        </div>
      </footer>
    </main>
  );
}
