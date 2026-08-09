#!/usr/bin/env bash
# Does this project actually have a working TURN relay?
#
# Two phones on one wifi connect directly and never need a relay, so calling can
# look perfect while being broken for every real pair of users. Two people
# behind different carrier NATs almost always need one. This answers the
# question without a second phone, a second network, or a debugger.
#
# Usage:
#   SUPABASE_URL=https://<ref>.supabase.co SUPABASE_ANON_KEY=<anon key> \
#     bash scripts/check-turn.sh
#
# Both values are in Supabase Dashboard -> Project Settings -> API. The anon key
# is safe to use here; it is the one the app itself ships with.

set -u

URL="${SUPABASE_URL:-}"
KEY="${SUPABASE_ANON_KEY:-}"

if [ -z "$URL" ] || [ -z "$KEY" ]; then
  echo "Set SUPABASE_URL and SUPABASE_ANON_KEY first. Both are in"
  echo "Supabase Dashboard -> Project Settings -> API."
  exit 2
fi

echo "Asking ${URL}/functions/v1/turn-credentials ..."
echo

BODY=$(curl -s -w $'\n%{http_code}' -X POST \
  "${URL}/functions/v1/turn-credentials" \
  -H "Authorization: Bearer ${KEY}" \
  -H "Content-Type: application/json" \
  -d '{}' --max-time 20)

CODE=$(printf '%s' "$BODY" | tail -n1)
JSON=$(printf '%s' "$BODY" | sed '$d')

echo "HTTP $CODE"
echo "$JSON" | head -c 1500
echo
echo

case "$CODE" in
  200)
    if printf '%s' "$JSON" | grep -q '"turn:\|"turns:\|turn:'; then
      echo "HEALTHY — the response contains a turn:/turns: relay."
      echo "Calls between users on different networks can connect."
    else
      echo "BROKEN — HTTP 200 but NO turn:/turns: entry in the response."
      echo "Only STUN came back. Two users on different networks will fail to"
      echo "connect, while two phones on your wifi will work fine."
    fi
    ;;
  000)
    echo "BROKEN — could not reach the function at all (network, or the URL is wrong)."
    ;;
  401|403)
    echo "BROKEN — auth rejected. Check the anon key, and that the function is"
    echo "not requiring a signed-in user for this call."
    ;;
  404)
    echo "BROKEN — the function is not deployed. Deploy it with:"
    echo "  supabase functions deploy turn-credentials"
    ;;
  500)
    echo "BROKEN — the function ran and failed. The body above says which:"
    echo "  turn_not_configured  -> the app_secrets rows are missing. In the SQL editor:"
    echo "     insert into app_secrets(key,value) values"
    echo "       ('CF_TURN_KEY_ID','<cloudflare turn key id>'),"
    echo "       ('CF_TURN_API_TOKEN','<cloudflare turn api token>');"
    echo "  secret_read_failed   -> the function cannot read app_secrets (service role / RLS)."
    ;;
  502)
    echo "BROKEN — Cloudflare rejected the request. The body above has their status."
    echo "Usually the API token is wrong, expired, or lacks the Realtime TURN permission."
    ;;
  *)
    echo "BROKEN — unexpected status. The body above is the detail."
    ;;
esac
