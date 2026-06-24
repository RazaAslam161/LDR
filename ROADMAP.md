# Miles — MVP Spec & Roadmap

> Working name: **Miles**
> Tagline: *"Feel close, even from here."*
> Platform: **Android (Flutter)** — Play Store launch, iOS to follow
> Goal: $100/mo recurring revenue within 6 months of launch.

---

## 1. Product Definition

### What it is
A native Android app for couples in long-distance relationships, built around the actual *experience of distance* — not chat, not a quiz app, but **presence**: breathe together, feel each other through the phone, watch the distance shrink.

### The wedge (what makes Miles new)
Other couples apps (Paired, Between, Agape) are *general couple tools* that happen to work for LDR. Miles is **LDR-native**, and ships four features no other LDR app has in combination:

1. **The Countdown** — to the second, beautiful, the daily-open driver
2. **Sky Bridge** — see your partner's sky right now (timezone-as-empathy)
3. **Breath Sync** — breathe together in real time, across continents
4. **Reach** — feel them through the phone (haptic heartbeat)

*"We breathe together from New York to Manila."* — that's the marketing hook nobody else can claim.

### What it is NOT
- Not a chat app (they already use WhatsApp)
- Not a video app
- Not an AI companion
- Not a generic couples quiz

---

## 2. Target User

**Primary persona:** "Maya & Jordan"
- Ages 22–34
- In a committed relationship, different cities/countries
- Timezone gap of 1–10 hours
- See each other every 1–6 months
- Use 3+ apps to coordinate (WhatsApp, shared calendar, countdown widgets)
- Frustrated that distance feels like a void between visits

**Where they live online:** r/LongDistance (380k), TikTok #LDR, Instagram, LDR Discord servers.

---

## 3. Tech Stack

| Layer | Tool | Notes |
|---|---|---|
| Framework | **Flutter 3.22+** | Cross-platform later (iOS), best animation tooling for the warm aesthetic |
| Language | **Dart 3.4+** | |
| State | **Riverpod** | Type-safe, testable |
| Routing | **go_router** | Auth-aware redirects |
| Backend | **Supabase** (Postgres + Auth + Realtime) | Schema in `/supabase` |
| Auth | Supabase Auth | Email/password for v1; Google lands in v1.1 |
| Realtime | Supabase Realtime | Powers Breath Sync + Reach + presence |
| Haptics | `vibration` package | For Reach |
| Fonts | Fraunces + Inter (`google_fonts`) | |

**Cost to run for first 50 users:** ~$0–5/mo. **Google Play dev account:** $25 one-time.

---

## 4. Core MVP Features (v1)

### F1. The Countdown ⏰
Live, to-the-second countdown to the next in-person visit. Beautiful, the home tab. Shows partner's local time at the visit moment. "You're together" state when the date arrives.

### F2. Sky Bridge 🌍
Two stacked gradient cards showing the actual sky state (dawn, golden hour, night) for each partner's city, with poetic lines ("Deep night. Probably asleep.") plus the timezone difference. The point is to *feel* their world without doing math.

### F3. Breath Sync 🫁
A pulsing orb guides 4-7-8 breathing. When one partner taps Begin, both phones pulse in unison via Supabase Realtime. *Breathe together across the world.*

### F4. Reach 📳
Hold the heart: your partner's phone vibrates in a heartbeat pattern. No message, no notification, just presence felt through the device.

### Explicitly deferred to v1.1+
- Ambient live wallpaper (Android-only superpower)
- Home-screen widget ("Right now for them")
- Visit timeline + year-in-review
- Sound postcards
- Conflict cooldown
- Daily LDR prompt
- Stripe billing
- Google sign-in
- iOS port

---

## 5. Project Structure

```
E:\LDR\
├── mobile/                     # Flutter app
│   ├── lib/
│   │   ├── main.dart
│   │   ├── core/              # theme, supabase, session, models, router
│   │   └── features/
│   │       ├── auth/          # sign_in, sign_up, welcome, couple
│   │       ├── shell/         # app_shell, app_drawer
│   │       ├── countdown/
│   │       ├── skybridge/
│   │       ├── breath/
│   │       └── reach/
│   ├── android/               # AndroidManifest, Gradle, MainActivity
│   └── pubspec.yaml
└── supabase/                  # SQL to run in the Supabase dashboard
    ├── schema.sql             # Tables + RLS + profile trigger
    ├── breath_events.sql      # Breath Sync realtime table
    └── reach_pulses.sql       # Reach haptic-pulse table
```

---

## 6. Database Schema

See [`supabase/schema.sql`](./supabase/schema.sql), [`supabase/breath_events.sql`](./supabase/breath_events.sql), [`supabase/reach_pulses.sql`](./supabase/reach_pulses.sql).

**Run order in Supabase SQL editor:**
1. `schema.sql`
2. `breath_events.sql`
3. `reach_pulses.sql`

All tables enforce Row Level Security tied to `couple_id`. No data ever crosses couple boundaries.

---

## 7. Design Principles

1. **Warm, not cute.** No cartoon mascots. Headspace × lingering text message.
2. **Slow interactions.** Soft transitions. Distance is patient.
3. **Dark mode first.** Couples check before bed.
4. **One screen, one job.** Don't clutter the countdown.
5. **Serif headlines, sans UI.** Fraunces + Inter.
6. **Color:** cream + deep navy + soft coral. Avoid generic blue/purple.

---

## 8. Pricing (v1.1)

| Tier | Price | Includes |
|---|---|---|
| **Free** | $0 | Countdown + Sky Bridge |
| **Together** | $5/mo or $39/yr | Breath Sync + Reach (the unique hooks) |

Strategy: lead with yearly. *"Less than a single date night."* Free tier is genuinely useful; the magic features gate the paid plan.

---

## 9. Roadmap & Milestones

### Phase 0 — Listening (Weeks 1–2)
- [ ] Read 100+ posts on r/LongDistance
- [ ] 5 LDR couples for 15-min calls
- [ ] Refine the v1 feature list
- [ ] Lock name + buy domain + Play Store listing draft

### Phase 1 — MVP Build (Weeks 3–6)
- [x] Week 3: Project scaffold, auth, couple linking ✅
- [x] Week 4: Countdown + Sky Bridge ✅
- [x] Week 5: Breath Sync + Reach ✅
- [ ] Week 6: Polish, icons, Play Store listing, internal QA

### Phase 2 — Soft Launch (Weeks 7–8)
- [ ] Onboard 5 friendly couples
- [ ] Weekly check-ins; fix top 3 pain points

### Phase 3 — Distribution (Months 3–4)
- [ ] 2 long-form posts ("What 30 LDR couples told me about distance")
- [ ] r/SideProject + r/LongDistance soft-launch with free codes
- [ ] TikTok: the Breath Sync video is the hook
- [ ] 20 LDR bloggers / YouTubers → lifetime free for honest review

### Phase 4 — Compounding (Months 5–6)
- [ ] v1.1: Stripe, Google sign-in, iOS port
- [ ] v1.2: Visit timeline + year-in-review (Dec viral moment)
- [ ] Partner with LDR merch shops
- [ ] Referral: invite another couple, both get a month free

---

## 10. Risks & Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Looks like every couples app | High | Breath Sync + Reach are unique hooks — lead with them |
| Can't find first users | Medium | r/LongDistance + TikTok are eager audiences |
| Partner won't download | High | Free tier is useful alone; invite is frictionless |
| Breath Sync feels awkward | Medium | Make it feel ritualistic, not gimmicky |
| Reach drains battery | Low | Ephemeral rows + cron cleanup |
| Churn after a visit | Medium | Sky Bridge + Breath Sync stay relevant even together |

---

## 11. Success Metrics

| Metric | v1 target |
|---|---|
| Couple signups | 30 by month 3 |
| Free → paid conversion | 30%+ (emotional product) |
| Weekly active couples | 60%+ of signups |
| Churn | <5%/mo |
| MRR | $100 by month 6 |

---

## 12. First Week of Work (concrete)

- [x] Day 1–2: Scaffold, theme, auth, session
- [x] Day 3: Couple linking + invite codes
- [x] Day 4: Countdown (the hook)
- [x] Day 5: Sky Bridge
- [x] Day 6: Breath Sync
- [x] Day 7: Reach

**End of week 1:** 4-feature Flutter app, fully wired to Supabase, ready for polish.

---

## 13. Open Questions to Resolve

1. **Final name + Play Store package ID** (current: `com.miles.app`)
2. **App icon** (needs a designer or a strong AI-generated mark)
3. **App Store screenshots** (5–7 in Play Store style)
4. **Privacy policy URL** (required by Play Store)
5. **iOS timing** — v1.1 after Android validates?

---

*Last updated: 2026-06-23*
*Status: MVP build complete — entering polish + Play Store prep*
