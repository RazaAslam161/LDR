"use client";

import { useState } from "react";
import { setNextVisit } from "@/app/actions";

export function SetVisitForm() {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    const res = await setNextVisit(new FormData(e.currentTarget));
    if (res?.error) {
      setError(res.error);
      setLoading(false);
    }
  }

  // Default: one month from today
  const defaultDate = (() => {
    const d = new Date();
    d.setMonth(d.getMonth() + 1);
    return d.toISOString().slice(0, 10);
  })();

  return (
    <form onSubmit={handleSubmit} className="space-y-4 text-left">
      <div>
        <label className="mb-1.5 block text-xs text-cream-100/50">
          Arrival date
        </label>
        <input
          type="date"
          name="startDate"
          required
          defaultValue={defaultDate}
          className="input"
        />
      </div>
      <div>
        <label className="mb-1.5 block text-xs text-cream-100/50">
          Where? (optional)
        </label>
        <input
          type="text"
          name="location"
          className="input"
          placeholder="Their city, your city, somewhere new…"
        />
      </div>

      {error && (
        <p className="rounded-xl bg-coral-500/10 px-4 py-3 text-sm text-coral-400">
          {error}
        </p>
      )}

      <button type="submit" disabled={loading} className="btn-primary w-full">
        {loading ? "Saving…" : "Start the countdown"}
      </button>
    </form>
  );
}
