# ART-PROMPTS — copy-paste, one prompt per asset

Every prompt below is SELF-CONTAINED. The constraints are repeated inside
each one on purpose: round one put them in a header, the generator never
re-read them, and three images came back with baked-in text while four came
back with blue/green colour fringing.

**Per asset:** generate → save PNG → `cwebp -q 80 in.png -o <name>.webp`
(backdrops: `-q 75`) → put it in `mobile/assets/art/` → say so, and it gets
wired to its call site.

**Approved already — do NOT regenerate:** `seal.webp`, `card_back.webp`,
`door.webp`.

---

## 1. `jar.webp` — wish jar hero · square 1024×1024 · ≤120KB
*(optional — the first is usable; this drops the butterflies and the heavy red)*

A corked clear glass jar standing on a dark surface, photographed slightly from below eye level. Inside the jar float dozens of tiny warm points of light like fireflies, in soft ember orange #E8674A and antique gold #D9A86C, some drifting near the top, some settled at the bottom. The glass rim catches warm candlelight. Background is pure near-black #120A0C. A gentle warm glow spills from the jar onto the surface beneath it. Cosy, intimate, candlelit night mood. The jar is centred with a generous dark margin all around it. Nothing inside the jar except the lights — no insects, no butterflies, no flowers, no paper, no labels. Absolutely no text, letters, words, numbers, captions, signatures, watermarks or interface elements of any kind — not even illegible or decorative lettering. No faces, no people, no animals. No chromatic aberration, no colour fringing, no RGB misregistration, no risograph offset. Warm palette only — no blue, cyan, teal or green anywhere.

## 2. `bg_midnight.webp` — Starlit chat backdrop · portrait 1024×2048 · q75 · ≤180KB
*(regen — the first had garbled lettering across the bottom)*

A deep navy night sky, extremely simple and almost empty, as a vertical portrait image. Smooth gradient from #0E1A3A at the top to #0A0F22 at the bottom, with a light scatter of very small faint stars in pale #9DA8C8 and one whisper-faint line of three or four stars suggesting a constellation. No moon, no clouds, no horizon, no landscape. The whole image must read as nearly solid dark navy at a glance — nothing in it larger than a tenth of the frame, no bright areas, no focal point. Slightly darker vignette toward the top and bottom edges. Absolutely no text, letters, words, numbers, captions, signatures, watermarks, borders, frames or interface elements of any kind — not even illegible or decorative lettering. No faces, no people, no animals. No chromatic aberration, no colour fringing, no RGB misregistration.

## 3. `bg_dawn.webp` — Dawn chat backdrop · portrait 1024×2048 · q75 · ≤180KB
*(regen — the first had garbled lettering across the middle)*

A soft warm cream paper texture filling the entire frame as a vertical portrait image, colour running from #F5E6DC at the top to #EAD3CB at the bottom, lit by a gentle diffuse morning light from above. Extremely subtle linen grain in the paper. Completely empty and even — no objects, no shapes, no shadows, no focal point, nothing larger than a tenth of the frame. The whole image must read as nearly solid warm cream at a glance. Absolutely no text, letters, words, numbers, captions, signatures, watermarks, borders, frames or interface elements of any kind — not even illegible or decorative lettering. No faces, no people, no animals. No chromatic aberration, no colour fringing, no RGB misregistration.

## 4. `bg_aurora.webp` — Aurora chat backdrop · portrait 1024×2048 · q75 · ≤180KB
*(regen — the first was a screenshot of an Instagram story, with the app's buttons and a real account name on it. Cannot ship.)*

A near-black night sky as a vertical portrait image, gradient from #241640 at the top to #103A3E at the bottom, with one extremely faint aurora ribbon in muted violet #7A57C9 drifting low in the frame at very low opacity, and five or six tiny soft stars. Everything very dim and understated — the whole image must read as nearly solid dark at a glance, with no bright areas and no focal point. Slightly darker vignette toward the top and bottom edges. A clean full-bleed image with nothing overlaid on it. Absolutely no text, letters, words, numbers, captions, signatures, watermarks, borders, frames, phone UI, app icons, buttons or interface elements of any kind — not even illegible or decorative lettering. No faces, no people, no animals. No chromatic aberration, no colour fringing, no RGB misregistration.

## 5. `bg_velvet.webp` — Midnight Boudoir backdrop · portrait 1024×2048 · q75 · ≤180KB
*(regen — the first was far too bright; this must be almost black)*

Deep plum velvet fabric in near-total darkness, filling the entire frame as a vertical portrait image. The colour range is only #1A0E16 to #2A1320 — almost black throughout, never bright, never saturated purple. A faint fabric weave catches one soft candlelight sheen, barely visible. The whole image must read as nearly solid black at a glance, with no bright areas and no focal point. Slightly darker vignette toward the top and bottom edges. Absolutely no text, letters, words, numbers, captions, signatures, watermarks, borders, frames or interface elements of any kind. No faces, no people, no animals. No chromatic aberration, no colour fringing, no RGB misregistration. No blue, cyan, teal or green anywhere.

## 6. `bg_rose.webp` — Blush backdrop · portrait 1024×2048 · q75 · ≤180KB
*(regen — the first's blooms were far too strong; these must be ghost-faint)*

A deep dark rose gradient filling the entire frame as a vertical portrait image, from #3A1A28 at the top to #2A1320 at the bottom, dark throughout. One very large, very soft watercolour bloom in dusty pink #E08AA0 sits in a single corner at extremely low opacity — barely perceptible, like a stain seen through dark glass, never bright and never pink-dominant. The whole image must read as nearly solid dark plum at a glance, with no bright areas and no focal point. Slightly darker vignette toward the top and bottom edges. Absolutely no text, letters, words, numbers, captions, signatures, watermarks, borders, frames or interface elements of any kind. No faces, no people, no animals. No chromatic aberration, no colour fringing, no RGB misregistration.

## 7. `bg_ember.webp` — Candlelit backdrop · portrait 1024×2048 · q75 · ≤180KB
*(not yet attempted)*

A very dark warm brown gradient filling the entire frame as a vertical portrait image, from #2A160E at the top to #4A2614 at the bottom. A faint candlelight glow sits low at the bottom edge, and a few subtle floating warm dust motes in #D9763E drift at very low opacity. Dark and even throughout — the whole image must read as nearly solid dark brown at a glance, with no bright areas and no focal point. Slightly darker vignette toward the top edge. Absolutely no text, letters, words, numbers, captions, signatures, watermarks, borders, frames or interface elements of any kind. No faces, no people, no animals, no candles or objects. No chromatic aberration, no colour fringing, no RGB misregistration. Warm palette only — no blue, cyan, teal or green anywhere.

## 8. `chest.webp` — capsule empty state · square 768×768 · ≤80KB
*(regen — the first had blue/cyan fringing on every edge)*

A minimal spot illustration of a small closed keepsake chest, flat illustration style with soft warm gradients, on a solid #120A0C background. A faint warm glow leaks from the seam under its lid. The palette is strictly ember orange #E8674A, antique gold #D9A86C, cream #FCEFE6 and deep plum-black #120A0C — nothing else. The chest is small and centred with a large empty margin around it. Clean flat edges throughout. Absolutely no text, letters, words, numbers, captions, signatures or watermarks. No faces, no people, no animals. No chromatic aberration, no colour fringing, no RGB misregistration, no risograph offset, no misaligned colour layers. Warm palette only — no blue, cyan, teal or green anywhere, including on edges and highlights.

## 9. `frame.webp` — gallery empty state · square 768×768 · ≤80KB
*(regen — the first had rainbow fringing across the whole frame)*

A minimal spot illustration of an empty ornate gilt picture frame, flat illustration style with soft warm gradients, on a solid #120A0C background. Two tiny ember sparks drift inside the empty opening. The palette is strictly antique gold #D9A86C, ember orange #E8674A, cream #FCEFE6 and deep plum-black #120A0C — nothing else. The frame is small and centred with a large empty margin around it. Clean flat edges throughout. Absolutely no text, letters, words, numbers, captions, signatures or watermarks. No faces, no people, no animals, no picture inside the frame. No chromatic aberration, no colour fringing, no RGB misregistration, no risograph offset, no misaligned colour layers, no rainbow edges. Warm palette only — no blue, cyan, teal or green anywhere.

## 10. `lantern.webp` — wish jar empty state · square 768×768 · ≤80KB
*(regen — the first had a blue border and was fully lit)*

A minimal spot illustration of a small round paper lantern hanging still, flat illustration style with soft warm gradients, on a solid #120A0C background that fills the entire frame edge to edge. The lantern is mostly dark, with one tiny ember just beginning to glow inside it — a small point of warm light, not a fully lit lantern. The palette is strictly ember orange #E8674A, antique gold #D9A86C, cream #FCEFE6 and deep plum-black #120A0C — nothing else. The lantern is small and centred with a large empty margin around it. Absolutely no text, letters, words, numbers, captions, signatures, watermarks, borders or frames of any kind. No faces, no people, no animals. No chromatic aberration, no colour fringing, no RGB misregistration. Warm palette only — no blue, cyan, teal or green anywhere, including borders and edges.

## 11. `thread.webp` — timeline empty state · square 768×768 · ≤80KB
*(regen — the first read as a scribble of light, not a thread in a knot)*

A minimal spot illustration of a single fine thread of warm golden light, tied once in a small simple open knot near the centre, its two loose ends trailing away and fading into darkness. Flat illustration style with a soft warm glow along the thread, on a solid #120A0C background filling the frame. One continuous clean line only — a deliberate, elegant knot, not a tangle, not a scribble, not a loop of neon tubing. The palette is strictly antique gold #D9A86C, cream #FCEFE6 and deep plum-black #120A0C. Small and centred with a large empty margin. Absolutely no text, letters, words, numbers, captions, signatures, watermarks, borders or frames of any kind. No faces, no people, no animals. No chromatic aberration, no colour fringing, no RGB misregistration. Warm palette only — no blue, cyan, teal or green anywhere, including borders and edges.

---

## Wiring status

| Asset | State |
|---|---|
| `seal.webp` | approved — awaiting the file |
| `card_back.webp` | approved — awaiting the file |
| `door.webp` | approved — awaiting the file |
| `jar.webp` | usable as-is; optional regen (prompt 1) |
| 6 chat backdrops | regen (prompts 2–7) |
| 4 empty states | regen (prompts 8–11) |

Size budgets are enforced by `mobile/test/unit/hygiene/asset_hygiene_test.dart`.
