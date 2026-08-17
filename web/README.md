# Miles — hosted legal & safety pages

The five documents Google Play requires to be reachable at a public URL, plus a
landing page so the site root does not 404 when a reviewer visits it.

Deployed to Vercel as the project **miles-legal**, from this directory. Redeploy
after any edit:

    cd E:\LDR\web
    npx vercel --prod

## Why these files live here and not in a copy

They are deployed straight from `web/`, which is also where the repo keeps them.
There is deliberately no second copy in a separate "site" folder: two sets of
legal pages that drift apart is precisely the failure a full audit had to fix
once already, and a privacy policy that disagrees with itself is worse than one
that is merely out of date.

`docs/legal/*.md` are the markdown sources of the same text and must be kept in
step by hand when a page changes.

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

## Outstanding

Nothing. The last `[PLACEHOLDER]` in `csae.html` was filled 2026-08-17: the
National Cyber Crime Investigation Agency (NCCIA — absorbed the FIA Cybercrime
Wing in 2025), complaint portal complaint.nccia.gov.pk, helpline 1799
(sources: nccia.gov.pk; thenews.pk/print/1402642 — Senate told NCCIA received
138k+ CSAM reports; nr3c.gov.pk now redirects to NCCIA). The live site serves
the old text until the next Vercel deploy.
