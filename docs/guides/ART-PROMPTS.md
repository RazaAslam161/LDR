# ART-PROMPTS — the Sensory Overhaul's generated art, one prompt per asset

Run each prompt in Nano Banana Pro, save the PNG, then convert and drop it at
the listed path. Every asset lands in the repo **together with the code that
uses it** — batches below match the wiring order.

**Convert:** `cwebp -q 80 in.png -o <name>.webp` (backdrops: `-q 75`).
**Global constraints — part of every prompt, never skip:** no faces, no human
figures, no text, no letters, no numbers, no watermark, no signature. No cold
blue anywhere except the Starlit backdrop. Nothing suggestive.
**Palette anchors:** night `#120A0C` · surface `#221017` · cream `#FCEFE6` ·
ember `#E8674A` · gilt `#D9A86C` · star violet `#8B7CF0`.

---

## Batch A — seal, card back, empty states

### 1. `mobile/assets/art/seal.webp` — capsule wax seal · 1:1 · 1024px · ≤120KB
> A round embossed wax seal photographed straight-on, deep ember-red wax with
> highlights of #E8674A over a dark #221017 body, embossed with an abstract
> interlocking double-loop knot motif — two closed loops linked, purely
> geometric, no letters, no symbols, no text. Warm gilt rim lighting in
> #D9A86C, candlelit mood, resting on a near-black #120A0C background, soft
> shadow, subtle antique grain, perfectly centered with generous dark margin.
> No faces, no text, no watermark.

### 2. `mobile/assets/art/card_back.webp` — game card back · 2:3 · 832×1248 · ≤100KB
> An ornate playing-card back design, flat vector style, portrait orientation.
> Symmetrical art-deco filigree border in warm gold #D9A86C on a near-black
> plum background #120A0C, with a small central diamond-shaped ember glow
> motif in #E8674A radiating faint warm light. Elegant, quiet, luxurious,
> candlelit mood. Perfectly symmetrical top-to-bottom and left-to-right. No
> letters, no numbers, no faces, no text, no watermark.

### 3–6. Empty-state spot illustrations · 1:1 · 768px · ≤80KB each
Shared frame (prepend to each): *"Minimal spot illustration, flat style with
soft warm gradients, on a #120A0C background, palette limited to #E8674A
#D9A86C #FCEFE6 #8B7CF0 over #120A0C, candlelit mood, small centered subject
with large empty margin, no faces, no text, no watermark."*

| File | Subject line |
|---|---|
| `chest.webp` (capsule list) | a small closed keepsake chest with a faint warm glow leaking from its seam |
| `frame.webp` (gallery) | an empty ornate gilt picture frame with two tiny ember sparks drifting inside it |
| `thread.webp` (timeline) | a single loose thread of warm golden light tied in a small open knot, ends trailing into darkness |
| `lantern.webp` (wish jar) | a small unlit paper lantern with one tiny ember beginning to glow inside |

## Batch B — backdrops, vault door, jar

### 7–12. Chat theme backdrops · 1:2 portrait · 1024×2048 · `-q 75` · ≤180KB each
Shared constraint (prepend to each): *"Extremely subtle, barely-visible
texture — must read as nearly solid color at a glance; no shapes larger than
a tenth of the frame; slightly darker vignette toward top and bottom edges."*

| File | Theme | Prompt core |
|---|---|---|
| `bg_velvet.webp` | Midnight Boudoir | deep plum velvet fabric texture in near-darkness, colors only #1A0E16 to #2A1320, faint fabric weave catching a candlelight sheen, almost black |
| `bg_ember.webp` | Candlelit | very dark warm brown gradient #2A160E to #4A2614 with faint drifting candlelight glow at the bottom edge and subtle floating warm dust motes in #D9763E at low opacity |
| `bg_aurora.webp` | Aurora | near-black night sky gradient #241640 to #103A3E with an extremely faint aurora ribbon in muted violet #7A57C9 and teal, plus five tiny soft stars, all at low opacity |
| `bg_rose.webp` | Blush | deep rose-dark gradient #3A1A28 to #2A1320 with a barely-visible large watercolor bloom of #E08AA0 in one corner |
| `bg_midnight.webp` | Starlit *(the one blue exception)* | deep navy night sky #0E1A3A to #0A0F22, a scatter of faint tiny stars in #9DA8C8, one whisper-subtle constellation line, no moon |
| `bg_dawn.webp` | Dawn *(the one light theme)* | soft warm cream paper texture #F5E6DC to #EAD3CB, gentle morning light gradient from the top, extremely subtle linen grain |

### 13. `mobile/assets/art/door.webp` — vault gate texture · 3:4 · 960×1280 · ≤150KB
> A dark lacquered panel texture, deep plum-black #221017, with a thin inlaid
> geometric border frame in antique gold #D9A86C and a small round brass dial
> ornament at center — abstract, no numbers, no letters. Warm low
> side-lighting, candlelit mood, subtle wood lacquer grain, mostly dark and
> empty. No faces, no text, no watermark.

### 14. `mobile/assets/art/jar.webp` — wish jar hero · 1:1 · 1024px · ≤120KB
*(Also the source image for the Higgsfield turntable — generate this one
first and best.)*
> A corked glass jar on a dark surface, seen slightly from below eye level,
> filled with dozens of tiny floating warm ember-orange lights like fireflies
> in #E8674A and #D9A86C, glass rim catching gilt candlelight, background
> pure near-black #120A0C, gentle glow spilling from the jar onto the
> surface, cozy candlelit night mood, centered, generous margin. No faces,
> no text, no labels on the jar, no watermark.

---

Budgets are enforced by `test/unit/hygiene/asset_hygiene_test.dart` (art
ceiling lands with the first art batch). Drop finished files in
`mobile/assets/art/` and say so — wiring lands the same day, each asset with
its call site.
