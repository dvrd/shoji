#!/bin/zsh
# Per-build port pipeline (A3). Produces a compact model.json for one
# macOS build from its dyld shared cache, without Ghidra:
#   carve SkyLight -> UUID/hash -> hooked-function address + entry bytes ->
#   dispatch table base -> op map decode -> model.json
# Heavy analysis (Ghidra) stays on demand for when the diff shows changes.
# usage: port-build.sh BUILD_TAG DYLD_CACHE_PATH
set -euo pipefail

TAG=$1
CACHE=$2
ROOT=$(git rev-parse --show-toplevel)
OUT="$ROOT/artifacts/windowserver-$TAG"
mkdir -p "$OUT/extracted" "$OUT/model"

echo "== [1/4] carve SkyLight"
ipsw dyld extract "$CACHE" /System/Library/PrivateFrameworks/SkyLight.framework/SkyLight --output "$OUT/extracted" >/dev/null
shasum -a 256 "$OUT/extracted/SkyLight" | tee "$OUT/model/skylight.sha256"

echo "== [2/4] identity + hooked function"
python3 - "$OUT" <<'EOF'
import json, struct, subprocess, sys, re
out = sys.argv[1]
d = open(f'{out}/extracted/SkyLight','rb').read()
ncmds, = struct.unpack_from('<I', d, 16)
off = 32
uuid = None
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from('<II', d, off)
    if cmd == 0x1b:
        uuid = d[off+8:off+24].hex()
        break
    off += cmdsize
nm = subprocess.run(['nm', f'{out}/extracted/SkyLight'], capture_output=True, text=True).stdout
def addr_of(pattern):
    m = re.search(rf'^([0-9a-f]+) [tT] {pattern}$', nm, re.M)
    return '0x' + m.group(1) if m else None
model = {'uuid': uuid,
         'hooked_function': {'name': '_CGXOrderWindowListSpaceSwitchOptions',
                             'address': addr_of(r'__ZL\d+CGXOrderWindowListSpaceSwitchOptions\w*')},
         'commit_function': {'name': 'PKGTransactionCommit',
                             'address': addr_of(r'__ZL\d+PKGTransactionCommit\w*')}}
json.dump(model, open(f'{out}/model/identity.json', 'w'), indent=1)
print(json.dumps(model, indent=1))
EOF

echo "== [3/4] entry bytes + dispatch table"
python3 - "$OUT" "$CACHE" <<'EOF'
import json, re, subprocess, sys
out, cache = sys.argv[1], sys.argv[2]
model = json.load(open(f'{out}/model/identity.json'))
hook = model['hooked_function']['address']
asm = subprocess.run(['ipsw', 'dyld', 'disass', cache, '--vaddr', hook, '--count', '4', '--quiet'],
                     capture_output=True, text=True).stdout
model['hooked_function']['entry'] = []
for line in asm.splitlines():
    m = re.match(r'(0x[0-9a-f]+):\s+((?:[0-9a-f]{2} )+)\s+(\S.*)', line)
    if m:
        model['hooked_function']['entry'].append({'bytes': m.group(2).strip(), 'insn': m.group(3)})
commit = model['commit_function']['address']
asm = subprocess.run(['ipsw', 'dyld', 'disass', cache, '--vaddr', commit, '--count', '400', '--quiet'],
                     capture_output=True, text=True).stdout
open(f'{out}/model/transaction-commit.asm', 'w').write(asm)
table = None
for m in re.finditer(r'adrp\s+x24, (0x[0-9a-f]+)\s*\n\s*(0x[0-9a-f]+):\s+[0-9a-f ]+\s+add\s+x24, x24, #(0x[0-9a-f]+)', asm):
    table = hex(int(m.group(1), 16) + int(m.group(3), 16))
    break
model['dispatch_table'] = {'base': table}
json.dump(model, open(f'{out}/model/identity.json', 'w'), indent=1)
print('table base:', table)
EOF

echo "== [4/4] decode op map"
TABLE_VA=$(python3 -c "import json; print(json.load(open('$OUT/model/identity.json'))['dispatch_table']['base'])")
python3 "$(git rev-parse --show-toplevel)/tools/window-interception/ghidra/decode-transaction-table.py" "$OUT/extracted/SkyLight" "$TABLE_VA" \
  > "$OUT/model/transaction-dispatch-table.txt"
tail -1 "$OUT/model/transaction-dispatch-table.txt"
python3 - "$OUT" <<'EOF'
import json, re, sys
out = sys.argv[1]
ops = {}
for line in open(f'{out}/model/transaction-dispatch-table.txt'):
    m = re.match(r'op (0x[0-9a-f]+)\s+signed=\S+\s+handler=(0x[0-9a-f]+)\s+meta=\S+\s*(.*)', line)
    if m:
        ops[m.group(1)] = {'handler': m.group(2), 'name': m.group(3)}
model = json.load(open(f'{out}/model/identity.json'))
model['dispatch_table']['ops'] = ops
json.dump(model, open(f'{out}/model/model.json', 'w'), indent=1)
print(f'model.json: {len(ops)} ops')
EOF
echo "model written to $OUT/model/model.json"
