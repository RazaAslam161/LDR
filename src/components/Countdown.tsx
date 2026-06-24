"use client";

import { useEffect, useState } from "react";

interface Props {
  targetDate: string;        // ISO timestamp
  partnerTimezone: string;   // for displaying partner's local time alongside
}

interface Remaining {
  days: number;
  hours: number;
  minutes: number;
  seconds: number;
  done: boolean;
}

function computeRemaining(target: number): Remaining {
  const diff = target - Date.now();
  if (diff <= 0) {
    return { days: 0, hours: 0, minutes: 0, seconds: 0, done: true };
  }
  return {
    days: Math.floor(diff / 86_400_000),
    hours: Math.floor((diff % 86_400_000) / 3_600_000),
    minutes: Math.floor((diff % 3_600_000) / 60_000),
    seconds: Math.floor((diff % 60_000) / 1_000),
    done: false,
  };
}

function pad(n: number): string {
  return n.toString().padStart(2, "0");
}

export function Countdown({ targetDate, partnerTimezone }: Props) {
  const targetMs = new Date(targetDate).getTime();
  const [now, setNow] = useState<Remaining>(() => computeRemaining(targetMs));

  useEffect(() => {
    // Re-sync every second for the to-the-second tick
    const id = setInterval(() => setNow(computeRemaining(targetMs)), 1000);
    return () => clearInterval(id);
  }, [targetMs]);

  // Partner's local time at the visit moment, for the small caption
  const partnerLocal = (() => {
    try {
      return new Intl.DateTimeFormat(undefined, {
        timeZone: partnerTimezone,
        weekday: "short",
        month: "short",
        day: "numeric",
        hour: "numeric",
        minute: "2-digit",
      }).format(new Date(targetDate));
    } catch {
      return null;
    }
  })();

  if (now.done) {
    return (
      <div className="animate-fade-in text-center">
        <p className="font-display text-5xl text-cream-50 sm:text-7xl">
          You&rsquo;re together.
        </p>
        <p className="mt-4 text-sm text-cream-100/50">
          Enjoy every minute. ✨
        </p>
      </div>
    );
  }

  const units = [
    { label: "days", value: now.days },
    { label: "hours", value: now.hours },
    { label: "minutes", value: now.minutes },
    { label: "seconds", value: now.seconds },
  ];

  return (
    <div className="animate-fade-in text-center">
      <div className="flex items-start justify-center gap-3 sm:gap-8">
        {units.map((u, i) => (
          <div key={u.label} className="flex items-start">
            <div>
              <div className="font-display text-5xl font-light tabular-nums text-cream-50 sm:text-8xl">
                {u.value < 100 ? pad(u.value) : u.value}
              </div>
              <div className="mt-2 text-xs uppercase tracking-[0.2em] text-cream-100/40">
                {u.label}
              </div>
            </div>
            {i < units.length - 1 && (
              <span className="mt-2 hidden font-display text-4xl text-cream-100/20 sm:block sm:text-6xl">
                :
              </span>
            )}
          </div>
        ))}
      </div>

      {partnerLocal && (
        <p className="mt-8 text-xs text-cream-100/40">
          That&rsquo;s {partnerLocal} their time
        </p>
      )}
    </div>
  );
}
