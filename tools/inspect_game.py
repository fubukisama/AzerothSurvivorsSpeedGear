"""Read-only PE inspection for the local Azeroth Survivors build."""
import argparse
import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '.deps' / 'python'))
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_64

parser = argparse.ArgumentParser()
parser.add_argument('exe')
args = parser.parse_args()
pe = pefile.PE(args.exe, fast_load=True)
pe.parse_data_directories(directories=[1, 3])
image = pe.get_memory_mapped_image()
md = Cs(CS_ARCH_X86, CS_MODE_64)
patterns = [bytes.fromhex('31 c9 ba 40 78 7d 01 e8'), bytes.fromhex('33 c9 ba 40 78 7d 01 e8')]
results = []
for section in pe.sections:
    if not section.Characteristics & 0x20000000:
        continue
    code = section.get_data()
    for pattern in patterns:
        start = 0
        while (at := code.find(pattern, start)) >= 0:
            rva = section.VirtualAddress + at
            call = rva + len(pattern) - 1
            target = call + 5 + struct.unpack_from('<i', image, call + 1)[0]
            hops = []
            for _ in range(3):
                if image[target] != 0xE9:
                    break
                hops.append(hex(target))
                target = target + 5 + struct.unpack_from('<i', image, target + 1)[0]
            runtime = next((e.struct for e in getattr(pe, 'DIRECTORY_ENTRY_EXCEPTION', []) if e.struct.BeginAddress <= target < e.struct.EndAddress), None)
            limit = min(runtime.EndAddress if runtime else target + 500, target + 1800)
            disasm = [f'{i.address:x}: {i.mnemonic} {i.op_str}' for i in md.disasm(image[target:limit], target)]
            results.append({'caller': hex(rva), 'return_rva': hex(call+5), 'target': hex(target), 'hops': hops,
                            'function_start': hex(runtime.BeginAddress) if runtime else None,
                            'function_end': hex(runtime.EndAddress) if runtime else None, 'instructions': disasm})
            start = at + 1
print(json.dumps({'image_size': hex(pe.OPTIONAL_HEADER.SizeOfImage), 'candidates': results}, indent=2))
