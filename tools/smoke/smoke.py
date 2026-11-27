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
BUILDS = ['spec/TestBuilds/3.13/Dual Savior.xml', 'spec/TestBuilds/3.13/Generals Perforate Zerker.xml',
          # Perforate build with extra "Level 12" / "Leveling lvl 40" trees (levelling planner)
          'tools/smoke/levelling.xml']
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
        ('plan', {'level': 25, 'questPoints': 4}),
        # Loot Goblin window: edit loadouts (the file isn't written; edit returns the XML)
        ('edit', {'path': path_for(b), 'ops': [
            {'op': 'newLoadout', 'spec': 1, 'itemSet': 1, 'skillSet': 1, 'title': 'Smoke loadout'},
            {'op': 'copySet', 'kind': 'tree', 'id': 1},
            {'op': 'renameSet', 'kind': 'tree', 'id': 1, 'title': 'Smoke rename'},
            {'op': 'gem', 'skillSet': 1, 'group': 1, 'gem': 1, 'level': 3, 'quality': 10},
            {'op': 'group', 'skillSet': 1, 'group': 1, 'enabled': True},
        ]}),
    ]
# Orbhoarder price check "vs character": gear from a character file (here: another build's file)
reqs += [
    ('load', {'path': path_for(BUILDS[0])}),
    ('equipped', {'file': path_for(BUILDS[1]), 'name': 'Smoke'}, 'equippedFile'),
    ('impact', {'item': RING}, 'impactLive'),
    ('clearEquipped', {}),
]
# Orbhoarder window: timeless jewel explorer + crafting simulator (last build stays loaded)
reqs += [
    ('timeless', {'sockets': True}),
    ('timeless', {'jewel': 'Lethal Pride', 'conqueror': 'Kaom', 'seed': 12345, 'socket': 26725}),
    ('timeless', {'jewel': 'Glorious Vanity', 'conqueror': 'Doryani', 'seed': 4321, 'socket': 26725}),
    ('timeless', {'jewel': 'Lethal Pride', 'socket': 26725, 'find': 'options'}),
    ('timeless', {'jewel': 'Glorious Vanity', 'socket': 26725, 'find': 'options'}),
    ('timeless', {'jewel': 'Lethal Pride', 'socket': 26725, 'find': 'search',
                  'wants': [{'label': '5% chance to deal Double Damage', 'min': 2}]}),
    ('craftBases', {}),
    ('craftMods', {'base': 'Vaal Regalia', 'ilvl': 86, 'influences': ['shaper']}),
]
reqs.append(('quit', {}))
stdin = ''.join(json.dumps({'id': i + 1, 'cmd': r[0], **r[1]}) + '\n' for i, r in enumerate(reqs))
proc = subprocess.run(cmd, cwd=SRC, input=stdin, capture_output=True, text=True, encoding='utf-8', errors='replace', env=env, timeout=900)

replies = {}
ready = None
for line in proc.stdout.splitlines():
    if line.startswith('@pob '):
        r = json.loads(line[5:])
        if r.get('id'):
            replies[r['id']] = r
        elif r.get('ready'):
            ready = r

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
    'edit': lambda r: 'Smoke loadout' in (r.get('xml') or '') and 'Smoke rename' in (r.get('xml') or '')
                      and (r.get('xml') or '').count('<Spec ') >= 3,
    'timeless': lambda r: len(r.get('jewels') or []) == 6 and (
        len(r.get('sockets') or []) > 10
        or (len((r.get('options') or {}).get('nodes') or []) > 3
            and all(n.get('options') for n in r['options']['nodes']))
        or ((r.get('search') or {}).get('complete', 0) > 0
            and all(h.get('label') == '5% chance to deal Double Damage'
                    for s in r['search']['seeds'][:5] for h in s.get('hits') or [])
            and len(r['search']['seeds'][0].get('hits') or []) >= 2)
        or any(
            n.get('newName') or n.get('stats') != n.get('before')
            for n in ((r.get('result') or {}).get('nodes') or []) if n.get('type') == 'Notable')),
    'equippedFile': lambda r: (r.get('equipped') or {}).get('fromFile') is True and (r['equipped'].get('items') or 0) >= 5,
    'impactLive': lambda r: nonempty(r.get('compares')) and nonempty((r.get('equipped') or {}).get('compares')),
    'craftBases': lambda r: len(r.get('bases') or []) > 200,
    'craftMods': lambda r: len(r.get('mods') or []) > 50 and r.get('influences') == ['shaper'],
    'plan': lambda r: nonempty(r.get('order')) and nonempty(r.get('phases')) and r.get('available') == 28 and isinstance(r.get('keptIds'), (list, dict)) and r.get('bandit') in ('None', 'Oak', 'Kraityn', 'Alira'),
}

failed = 0
# Orbhoarder reads caps from the ready line (S6): every command it sends must be listed
caps = (ready or {}).get('caps') or []
missing = sorted({r[0] for r in reqs} - set(caps)) + [f for f in ('equipped.file', 'timeless.find') if f not in caps]
if not ready or ready.get('fork') != 'deathloom' or ready.get('protocol') != 1 or missing:
    print(f'FAIL ready: caps missing {missing} or no fork/protocol: {json.dumps(ready)[:300]}'); failed += 1
else:
    print(f'ok   ready ({len(caps)} caps)')
for i, req in enumerate(reqs):
    c = req[2] if len(req) > 2 else req[0]
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
