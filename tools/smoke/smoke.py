#!/usr/bin/env python3
"""Deathloom fork: smoke test for the headless commands Loot Goblin uses.

Upstream merges can change PoB internals (item comparison, tree fields,
loadouts) without any merge conflict. This runs every ImpactServer command
the overlay calls against PoB's own test builds and fails on any error or
empty answer.

  Windows (CI):  python tools/smoke/smoke.py
  Linux:         python3 tools/smoke/smoke.py --wine
"""
import json, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, 'src')
BUILDS = ['spec/TestBuilds/3.13/Dual Savior.xml', 'spec/TestBuilds/3.13/Generals Perforate Zerker.xml']
RING = '\n'.join([
    'Item Class: Rings', 'Rarity: Rare', 'Smoke Loop', 'Two-Stone Ring', '--------',
    'Item Level: 80', '--------', '+12% to Fire and Cold Resistances (implicit)', '--------',
    '+60 to maximum Life', '+40% to Lightning Resistance', '+30 to Strength',
])

def path_for(p):
    full = os.path.join(ROOT, p)
    return ('Z:' + full) if WINE else full

WINE = '--wine' in sys.argv
exe = os.path.join(ROOT, 'runtime', 'PoBHeadless.exe')
cmd = (['wine', exe] if WINE else [exe]) + ['ImpactServer.lua']
env = dict(os.environ, WINEDEBUG='-all')

reqs = []
for b in BUILDS:
    reqs += [
        ('load', {'path': path_for(b)}),
        ('info', {}),
        ('impact', {'item': RING}),
        ('gear', {}),
        ('loadouts', {}),
        ('gems', {}),
        ('tree', {}),
        ('treeMap', {}),
    ]
reqs.append(('quit', {}))
stdin = ''.join(json.dumps({'id': i + 1, 'cmd': c, **p}) + '\n' for i, (c, p) in enumerate(reqs))
proc = subprocess.run(cmd, cwd=SRC, input=stdin, capture_output=True, text=True, encoding='utf-8', errors='replace', env=env, timeout=900)

replies = {}
for line in proc.stdout.splitlines():
    if line.startswith('@pob '):
        r = json.loads(line[5:])
        if r.get('id'):
            replies[r['id']] = r

def nonempty(v):
    return bool(v) and v != {}

CHECKS = {
    'load': lambda r: nonempty(r.get('build')) or r.get('ok'),
    'impact': lambda r: nonempty(r.get('compares')),
    'gear': lambda r: nonempty(r.get('items')),
    'loadouts': lambda r: nonempty(r.get('loadouts')),
    'gems': lambda r: nonempty(r.get('groups')),
    'tree': lambda r: nonempty((r.get('tree') or {}).get('nodes')),
    'treeMap': lambda r: len((r.get('layout') or {}).get('nodes') or []) > 1000
                         and len((r.get('layout') or {}).get('links') or []) > 1000
                         and nonempty((r.get('alloc') or {}).get('ids')),
}

failed = 0
for i, (c, _) in enumerate(reqs):
    r = replies.get(i + 1)
    if r is None:
        print(f'FAIL {c}: no reply'); failed += 1; continue
    if not r.get('ok'):
        print(f'FAIL {c}: {r.get("error")}'); failed += 1; continue
    check = CHECKS.get(c)
    if check and not check(r):
        print(f'FAIL {c}: empty or unexpected answer: {json.dumps(r)[:300]}'); failed += 1; continue
    print(f'ok   {c}')

if failed:
    print('--- stderr (tail) ---')
    print('\n'.join(proc.stderr.splitlines()[-30:]))
    sys.exit(1)
print(f'All {len(reqs)} commands answered.')
