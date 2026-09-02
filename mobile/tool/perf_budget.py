#!/usr/bin/env python3
"""Performance budgets that need a handset, as a pass/fail check.

`flutter test` cannot measure a cold start or a resident set, so the asset
suite gates size and nothing gates time. This measures both on an attached
phone and fails when either crosses its budget. Run it from mobile/ after an
install; the numbers it prints are the ones DEVICE-CHECKLIST.md asks for.

    python tool/perf_budget.py --serial 1896b4b3 [--runs 3]

Budgets are the rating's targets, not today's numbers: the first measured run
(2026-09-02, build 73) was 3516 ms / 324 MB on a OnePlus 8 and 2331 ms /
235 MB on a OnePlus 7, so this fails today by design — it is the number the
cold-start work has to move, written where it cannot be forgotten. Override
with --start-ms / --pss-mb to hold a regression line instead.
"""
import argparse
import os
import re
import statistics
import subprocess
import sys
import time

ADB = os.path.expanduser('~/AppData/Local/Android/Sdk/platform-tools/adb.exe')
if not os.path.exists(ADB):
    ADB = 'adb'
PKG = 'com.miles.miles'
ALIAS = 'com.miles.miles/.AliasMiles'


def adb(serial, *args, timeout=60):
    r = subprocess.run([ADB, '-s', serial, *args], capture_output=True,
                       text=True, timeout=timeout)
    # A phone that drops off the bus mid-run answered every question with an
    # empty string, and "not installed" was the wrong diagnosis it produced.
    if r.returncode != 0:
        sys.exit(f'adb {" ".join(args)} failed on {serial}: '
                 f'{(r.stderr or r.stdout).strip()}')
    return r.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--serial', required=True)
    ap.add_argument('--runs', type=int, default=3)
    ap.add_argument('--start-ms', type=int, default=1500,
                    help='cold start budget, am start -W TotalTime (default 1500)')
    ap.add_argument('--pss-mb', type=int, default=150,
                    help='resident set budget on the home screen (default 150)')
    args = ap.parse_args()
    s = args.serial

    model = adb(s, 'shell', 'getprop', 'ro.product.model').strip()
    vc = re.search(r'versionCode=(\d+)', adb(s, 'shell', 'dumpsys', 'package', PKG))
    if not vc:
        print(f'{PKG} is not installed on {s}')
        return 1
    print(f'{s} ({model}) build {vc.group(1)}')

    starts = []
    for i in range(args.runs):
        adb(s, 'shell', 'am', 'force-stop', PKG)
        time.sleep(2)
        out = adb(s, 'shell', 'am', 'start', '-W', '-n', ALIAS)
        m = re.search(r'TotalTime:\s*(\d+)', out)
        if not m:
            print(f'run {i + 1}: am start gave no TotalTime:\n{out}')
            return 1
        starts.append(int(m.group(1)))
        print(f'run {i + 1}: cold start {starts[-1]} ms')
        time.sleep(8)
    median = int(statistics.median(starts))

    mem = adb(s, 'shell', 'dumpsys', 'meminfo', PKG)
    m = re.search(r'TOTAL PSS:\s*(\d+)', mem) or re.search(r'TOTAL\s+(\d+)', mem)
    if not m:
        print('dumpsys meminfo gave no TOTAL PSS')
        return 1
    pss_mb = int(m.group(1)) // 1024
    print(f'cold start median {median} ms (budget {args.start_ms}); '
          f'PSS {pss_mb} MB (budget {args.pss_mb})')

    bad = []
    if median > args.start_ms:
        bad.append(f'cold start {median} ms > {args.start_ms} ms')
    if pss_mb > args.pss_mb:
        bad.append(f'PSS {pss_mb} MB > {args.pss_mb} MB')
    if bad:
        print('RED: ' + '; '.join(bad))
        return 1
    print('GREEN')
    return 0


if __name__ == '__main__':
    sys.exit(main())
