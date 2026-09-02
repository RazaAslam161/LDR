#!/usr/bin/env python3
"""The two-handset E2EE chat check, with the database as the oracle.

The couple key exists only on the phones, so no test on this machine can
produce a real ciphered message: a person types one on each handset. What a
person cannot see is whether the rows were cipher-only, whether either phone
filed a decrypt failure, and whether both read watermarks moved — and during
the dual-write era a broken decrypt was INVISIBLE on screen (the plaintext
rendered). This script reads those three facts and refuses to call the check
green without them. BRAIN §254 is the run it automates.

    export MILES_SUPABASE_SERVICE_KEY=...   # service_role: client_errors has no
                                            # select policy for any client role
    python tool/two_phone_chat_check.py --a 1896b4b3 --b a959ee2b

Exit 0 only when: both phones are attached and run the same versionCode, at
least one message per direction landed since the script started, every text
row since then is cipher-only (body NULL, cipher present, 24-byte nonce), no
client_errors row of kind chat-decrypt was filed, and both partners' read
watermarks reached the newest message. Anything else exits 1 and says why.
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone

PROD = 'https://sopictusdonlvuezmfep.supabase.co'
ADB = os.path.expanduser('~/AppData/Local/Android/Sdk/platform-tools/adb.exe')
if not os.path.exists(ADB):
    ADB = 'adb'
PKG = 'com.miles.miles'


def adb(serial, *args):
    out = subprocess.run([ADB, '-s', serial, *args], capture_output=True,
                         text=True, timeout=60)
    # A phone off the bus answers every question with an empty string; the
    # wrong diagnosis that produces is worse than the real one from adb.
    if out.returncode != 0:
        sys.exit(f'adb {" ".join(args)} failed on {serial}: '
                 f'{(out.stderr or out.stdout).strip()}')
    return out.stdout.strip()


def rest(path, key):
    req = urllib.request.Request(
        PROD + '/rest/v1/' + path,
        headers={'apikey': key, 'Authorization': 'Bearer ' + key},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode('utf-8'))


def bytea_len(v):
    """PostgREST renders bytea as '\\x' + hex; None stays None."""
    if v is None:
        return None
    if isinstance(v, str) and v.startswith('\\x'):
        return (len(v) - 2) // 2
    return -1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--a', required=True, help='serial of the first phone')
    ap.add_argument('--b', required=True, help='serial of the second phone')
    ap.add_argument('--wait', type=int, default=300,
                    help='seconds to wait for the two messages (default 300)')
    args = ap.parse_args()
    key = os.environ.get('MILES_SUPABASE_SERVICE_KEY', '')
    if not key:
        print('MILES_SUPABASE_SERVICE_KEY is not set; client_errors cannot be read '
              'with anything less (insert-only for every client role).')
        return 1

    failures = []
    versions = {}
    for s in (args.a, args.b):
        info = adb(s, 'shell', 'dumpsys', 'package', PKG)
        vc = [l.strip() for l in info.splitlines() if 'versionCode=' in l]
        if not vc:
            failures.append(f'{s}: {PKG} is not installed or the phone is not attached')
            continue
        versions[s] = vc[0].split()[0]
        print(f'{s}: {vc[0]}')
    if len(set(versions.values())) > 1:
        failures.append(f'the phones run different builds: {versions}')
    if failures:
        print('\n'.join(failures))
        return 1

    since = datetime.now(timezone.utc).replace(microsecond=0)
    since_iso = since.isoformat().replace('+00:00', 'Z')
    flag = rest('app_release?select=chat_cipher_only,min_build', key)[0]
    print(f'app_release: chat_cipher_only={flag["chat_cipher_only"]} '
          f'min_build={flag["min_build"]}')
    print(f'\nNow, from {since_iso}: type one message on phone {args.a}, then one on '
          f'phone {args.b}, with the chat open on both. Waiting up to {args.wait}s.')

    q = ('messages?select=seq,sender_id,body,body_cipher,body_nonce,created_at,kind'
         f'&kind=eq.text&created_at=gte.{urllib.parse.quote(since_iso)}&order=seq.asc')
    rows = []
    deadline = time.time() + args.wait
    while time.time() < deadline:
        rows = rest(q, key)
        senders = {r['sender_id'] for r in rows}
        if len(senders) >= 2:
            break
        time.sleep(5)
    senders = {r['sender_id'] for r in rows}
    if len(senders) < 2:
        failures.append(f'expected a message from each phone; got {len(rows)} row(s) '
                        f'from {len(senders)} sender(s)')

    for r in rows:
        c, n = bytea_len(r['body_cipher']), bytea_len(r['body_nonce'])
        state = ('cipher-only' if r['body'] is None and c else
                 'DUAL-WRITE' if r['body'] is not None and c else 'PLAINTEXT-ONLY')
        print(f'  seq {r["seq"]} from {r["sender_id"][:8]}: {state}, cipher {c} B, nonce {n} B')
        if r['body'] is not None:
            failures.append(f'seq {r["seq"]} carries plaintext (chat_cipher_only should make it cipher-only)')
        if not c:
            failures.append(f'seq {r["seq"]} has no ciphertext')
        if n != 24:
            failures.append(f'seq {r["seq"]} nonce is {n} bytes, not 24')

    errs = rest('client_errors?select=received_at,build,kind,error_type,detail'
                f'&received_at=gte.{urllib.parse.quote(since_iso)}&order=received_at.asc', key)
    decrypt = [e for e in errs if e['kind'] == 'chat-decrypt']
    print(f'client_errors since start: {len(errs)} total, {len(decrypt)} chat-decrypt')
    for e in decrypt:
        failures.append(f'chat-decrypt filed at {e["received_at"]} (build {e["build"]}): {e["detail"]}')

    if rows:
        newest = max(r['seq'] for r in rows)
        rec = rest('chat_receipts?select=user_id,delivered_seq,read_seq', key)
        for rr in rec:
            print(f'  receipts {rr["user_id"][:8]}: delivered {rr["delivered_seq"]} read {rr["read_seq"]}')
            # The sender's own watermark need not reach its own message; the
            # partner's must.
            if rr['read_seq'] < newest and rr['user_id'] != next(
                    r['sender_id'] for r in rows if r['seq'] == newest):
                failures.append(f'{rr["user_id"][:8]} has not read seq {newest} yet')

    if failures:
        print('\nRED:')
        print('\n'.join('  - ' + f for f in failures))
        return 1
    print('\nGREEN: both directions cipher-only, decrypted (read) on the other phone, '
          'no decrypt failure filed.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
