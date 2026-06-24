import Link from "next/link";
import { getCurrentUser } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { signOut } from "@/app/actions";

export default async function AppLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const user = await getCurrentUser();

  // Show partner status if available
  let partnerName: string | null = null;
  let partnerPresence: string | null = null;
  if (user?.partner) {
    partnerName = user.partner.display_name;
    partnerPresence = user.partner.presence_status;
  }

  const navItems = [
    { href: "/app", label: "Countdown", emoji: "⏰" },
    { href: "/app/rituals", label: "Rituals", emoji: "🌍" },
    { href: "/app/prompt", label: "Today", emoji: "💭" },
    { href: "/app/timeline", label: "Timeline", emoji: "📅" },
    { href: "/app/settings", label: "Settings", emoji: "⚙️" },
  ];

  return (
    <div className="flex min-h-screen">
      {/* Sidebar */}
      <aside className="hidden w-60 shrink-0 flex-col border-r border-cream-100/5 px-4 py-8 md:flex">
        <Link href="/app" className="mb-10 flex items-center gap-2 px-3">
          <div className="h-2 w-2 rounded-full bg-coral-500 animate-pulse-soft" />
          <span className="font-serif text-lg">Miles</span>
        </Link>

        <nav className="space-y-1">
          {navItems.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className="flex items-center gap-3 rounded-2xl px-3 py-2.5 text-sm text-cream-100/60 transition hover:bg-cream-50/5 hover:text-cream-50"
            >
              <span className="text-base">{item.emoji}</span>
              {item.label}
            </Link>
          ))}
        </nav>

        <div className="mt-auto space-y-4">
          {partnerName && (
            <div className="rounded-2xl bg-navy-900/60 p-3">
              <p className="text-xs text-cream-100/40">Your person</p>
              <div className="mt-1 flex items-center gap-2">
                <span
                  className={`h-1.5 w-1.5 rounded-full ${
                    partnerPresence === "asleep"
                      ? "bg-cream-100/30"
                      : partnerPresence === "busy"
                        ? "bg-coral-500"
                        : "bg-emerald-400"
                  }`}
                />
                <span className="text-sm text-cream-50">{partnerName}</span>
              </div>
            </div>
          )}

          <form action={signOut}>
            <button
              type="submit"
              className="px-3 text-xs text-cream-100/40 transition hover:text-cream-50"
            >
              Sign out
            </button>
          </form>
        </div>
      </aside>

      {/* Mobile top bar */}
      <div className="fixed inset-x-0 bottom-0 z-10 flex items-center justify-around border-t border-cream-100/5 bg-navy-950/90 px-2 py-2 backdrop-blur md:hidden">
        {navItems.map((item) => (
          <Link
            key={item.href}
            href={item.href}
            className="flex flex-col items-center gap-0.5 rounded-xl px-2 py-1 text-[10px] text-cream-100/50"
          >
            <span className="text-base">{item.emoji}</span>
            {item.label}
          </Link>
        ))}
      </div>

      {/* Main content */}
      <main className="flex-1 overflow-y-auto px-6 py-10 pb-24 md:pb-10">
        {children}
      </main>
    </div>
  );
}
