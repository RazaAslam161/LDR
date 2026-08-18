-- The one genuinely new advisor WARN in the 42 (2026-08-18):
-- storage_quota_bytes() shipped without a pinned search_path — the only
-- function in public missing the hardening every sibling carries. A mutable
-- search_path lets a caller-controlled schema shadow the objects a function
-- names; pinning it is one statement and closes the lint for real, unlike
-- the 39 per-RPC WARNs, which are the linter counting the API's surface.
--
-- Second run: no-op (ALTER to the same value).
--
-- ── ROLLBACK ───────────────────────────────────────────────────────────────
--   alter function public.storage_quota_bytes() reset search_path;
-- ───────────────────────────────────────────────────────────────────────────

alter function public.storage_quota_bytes() set search_path = public;
