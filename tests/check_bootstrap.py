"""Reject bootstrap code that refers outside its copied Mach-O section."""
import re
import subprocess
import sys

for binary in sys.argv[1:]:
    output = subprocess.check_output(
        ["xcrun", "llvm-objdump", "--disassemble", "--section=__shoji_boot", binary],
        text=True,
    )
    instructions = []
    for line in output.splitlines():
        match = re.match(r"^\s*([0-9a-f]+):\s+(?:(?:[0-9a-f]{8}|[0-9a-f]{2})\s+)+\s*([a-z][a-z0-9.]*)\s*(.*)$", line)
        if match:
            instructions.append((int(match[1], 16), match[2], match[3]))
    assert instructions, f"{binary}: missing bootstrap instructions"
    assert "remote_worker" in output and "remote_entry" in output
    addresses = {address for address, _, _ in instructions}
    for address, op, operands in instructions:
        operands = operands.split("<", 1)[0].split(";", 1)[0]
        assert "%rip" not in operands, (binary, hex(address), "RIP-relative data")
        assert op not in ("adr", "adrp"), (binary, hex(address), "PC-relative data")
        # Direct branches must stay in the copied section. Calls through registers
        # or Bootstrap fields intentionally have no literal target address.
        branch = op in ("b", "bl", "cbz", "cbnz", "tbz", "tbnz") or op.startswith(("b.", "j", "call"))
        if branch and not operands.lstrip().startswith("*"):
            for target in re.findall(r"0x([0-9a-f]+)", operands):
                assert int(target, 16) in addresses, (binary, hex(address), "external branch", target)
        if op.startswith("ldr"):
            assert not re.search(r",\s*0x[0-9a-f]+", operands), (binary, "literal load")
    print(f"{binary}: {len(instructions)} relocation-independent bootstrap instructions checked")
