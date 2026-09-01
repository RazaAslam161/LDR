# Miles — hosted legal & safety pages

The five documents Google Play requires to be reachable at a public URL, plus a
landing page so the site root does not 404 when a reviewer visits it, plus
`security.html` and `.well-known/security.txt` — which Play does not ask for and
which a researcher holding a sideloaded APK has no other way to reach.

Deployed to Vercel as the project **miles-legal**, from this directory. Redeploy
after any edit:

    cd D:\Miles\web
    npx vercel --prod

## Why these files live here and not in a copy

They are deployed straight from `web/`, which is also where the repo keeps them.
There is deliberately no second copy in a separate "site" folder: two sets of
legal pages that drift apart is precisely the failure a full audit had to fix
once already, and a privacy policy that disagrees with itself is worse than one
that is merely out of date.

This directory is the single source for the legal text. The in-app copies
(`mobile/lib/features/legal/faq_text.dart`, `terms_text.dart`) mirror it by hand
and must be updated in the same change.

## Cross-links are relative, so all pages deploy together

Every page links to the others as `href="terms.html"` and so on. Uploading a
subset leaves dead links between documents — and a reviewer clicking from the
privacy policy to the child-safety page and getting a 404 is exactly the sort of
thing that stalls a review.

## The CSP in vercel.json, and the one relaxation in it

`default-src 'none'` with everything else named explicitly. Two notes for
whoever tightens it next:

- **`script-src 'unsafe-inline'` is required.** `delete-account.html` carries an
  inline `<script>` that POSTs to the `account-delete` edge function. It is the
  only interactive page in the set, and it is one Play requires to work.
  Removing `'unsafe-inline'` silently breaks the deletion form — the page still
  renders, the button just stops doing anything.
- **`connect-src`** names the Supabase project that script calls. Nothing else
  is permitted to be contacted, and no external asset of any kind is loaded:
  every page is self-contained, with no CDN, no remote font and no remote image.

JSON has no comments and Vercel's schema rejects unknown keys, which is why this
reasoning is here rather than beside the config.

## `.well-known/security.txt`, and the second headers block

RFC 9116 fixes the path: a scanner or a disclosure platform looks for
`/.well-known/security.txt` and nowhere else, so the file cannot be moved
somewhere more convenient. It is the machine-readable half of `security.html`;
the two must agree, and the `Policy:` field in the file points at the page.

`vercel.json` gained a second `headers` block pinning
`Content-Type: text/plain; charset=utf-8` on that one path. It is not
decoration: the site-wide block sets `X-Content-Type-Options: nosniff`, so if
the host ever answers that path with anything other than `text/plain` the
browser will refuse to sniff its way to the right answer and the file becomes
unreadable in the one place it is meant to be read. `headers` was extended
rather than `routes` added, because Vercel rejects a config carrying both.

**Verify it after the next deploy, do not assume it.** A dot-directory is the
one thing in this folder whose upload has never been proven here:

    curl -i https://miles-legal.vercel.app/.well-known/security.txt

Expect `200` and `content-type: text/plain; charset=utf-8`. A `404` means the
dot-directory did not survive the upload, and the fix is a `rewrites` entry to a
non-dot path — not a second copy of the file, which is the drift this README
warns about above.

## Live status (checked 2026-09-02)

    curl -sS -o /dev/null -w '%{http_code} %{content_type}' https://miles-legal.vercel.app/.well-known/security.txt
    200 text/plain; charset=utf-8

`security.html` and `csae.html` also answer 200. The `csae.html` contact block
names the National Cyber Crime Investigation Agency (NCCIA; complaint portal
complaint.nccia.gov.pk, helpline 1799), filled 2026-08-17.
