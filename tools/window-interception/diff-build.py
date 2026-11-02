#!/usr/bin/env python3
"""Diff two per-build port models (A3).

Compares artifacts/windowserver-<tag>/model/model.json pairs and prints a
porting report: identity, hooked function, dispatch table base, and the
op map. Op-name movement is the porting signal; raw address changes are
expected on every build. usage: diff-build.py REF_TAG NEW_TAG
"""
import json
import subprocess
import sys

ROOT = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True).stdout.strip()

def load(tag):
    return json.load(open(f'{ROOT}/artifacts/windowserver-{tag}/model/model.json'))

if len(sys.argv) != 3:
    sys.exit('usage: diff-build.py REF_TAG NEW_TAG')
ref, new = load(sys.argv[1]), load(sys.argv[2])

print(f'=== {sys.argv[1]} -> {sys.argv[2]}')
print(f"uuid:            {ref['uuid']} -> {new['uuid']}  {'MATCH' if ref['uuid'] == new['uuid'] else 'CHANGED (gates will refuse)'}")

rh, nh = ref['hooked_function'], new['hooked_function']
print(f"hooked function: {rh['address']} -> {nh['address']}")
rb = [e['bytes'] for e in rh.get('entry', [])]
nb = [e['bytes'] for e in nh.get('entry', [])]
print(f"entry bytes:     {'MATCH' if rb == nb else 'CHANGED — re-verify prologue/trampoline'}")
for a, b in zip(rh.get('entry', []), nh.get('entry', [])):
    mark = ' ' if a['bytes'] == b['bytes'] else '!'
    print(f"  {mark} {a['bytes']}  {a['insn']}   |   {b['bytes']}  {b['insn']}")

rt, nt = ref['dispatch_table'], new['dispatch_table']
print(f"dispatch table:  {rt['base']} -> {nt['base']}")
rops, nops = rt.get('ops', {}), nt.get('ops', {})
missing = sorted(set(rops) - set(nops))
added = sorted(set(nops) - set(rops))
renamed = [op for op in sorted(set(rops) & set(nops)) if rops[op]['name'] != nops[op]['name']]
moved = [op for op in sorted(set(rops) & set(nops)) if rops[op]['handler'] != nops[op]['handler']]
print(f"ops: ref={len(rops)} new={len(nops)}")
print(f"  missing ops:  {missing or 'none'}")
print(f"  added ops:    {added or 'none'}")
print(f"  renamed ops:  {renamed or 'none'}")
print(f"  moved handlers (expected on any build): {len(moved)}")
gated = [op for op in moved if int(op, 16) in (0x01, 0x03, 0x06, 0x0b, 0x18, 0x19, 0x21, 0x22, 0x2a, 0x33, 0x34, 0x35, 0x36, 0x41)]
print(f"  gated ops moved: {gated or 'none'}")
verdict = 'PORT CLEAN' if ref['uuid'] == new['uuid'] and rb == nb and not (missing or renamed) else 'PORT NEEDED'
print(f'verdict: {verdict}')
