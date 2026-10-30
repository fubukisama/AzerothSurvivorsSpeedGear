"""Generate lazy forwarding thunks from the system DWM export table (build time only)."""
import os
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '.deps' / 'python'))
import pefile

root = Path(__file__).resolve().parents[1]
system_dwm = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32' / 'dwmapi.dll'
pe = pefile.PE(str(system_dwm), fast_load=True)
pe.parse_data_directories(directories=[0])
symbols = sorted(pe.DIRECTORY_ENTRY_EXPORT.symbols, key=lambda s: s.ordinal)
defs = ['LIBRARY dwmapi', 'EXPORTS']
asm = ['option casemap:none', 'EXTERN ProxyGetFunction:PROC', '.code']
entries = []
for i, symbol in enumerate(symbols):
    name = symbol.name.decode('ascii') if symbol.name else None
    stub = f'forward_{i}'
    defs.append(f'  {name or stub}={stub} @{symbol.ordinal}' + ('' if name else ' NONAME') + (' PRIVATE' if name in ('DllCanUnloadNow','DllGetClassObject') else ''))
    entries.append(f'  {{"{name}", {symbol.ordinal}}},' if name else f'  {{nullptr, {symbol.ordinal}}},')
    asm.extend([
        f'{stub} PROC FRAME', '  sub rsp, 0A8h', '  .allocstack 0A8h', '  .endprolog',
        '  mov [rsp+20h], rcx', '  mov [rsp+28h], rdx', '  mov [rsp+30h], r8', '  mov [rsp+38h], r9',
        '  movdqu [rsp+40h], xmm0', '  movdqu [rsp+50h], xmm1', '  movdqu [rsp+60h], xmm2', '  movdqu [rsp+70h], xmm3',
        f'  mov ecx, {i}', '  call ProxyGetFunction',
        '  mov rcx, [rsp+20h]', '  mov rdx, [rsp+28h]', '  mov r8, [rsp+30h]', '  mov r9, [rsp+38h]',
        '  movdqu xmm0, [rsp+40h]', '  movdqu xmm1, [rsp+50h]', '  movdqu xmm2, [rsp+60h]', '  movdqu xmm3, [rsp+70h]',
        '  add rsp, 0A8h', '  jmp rax', f'{stub} ENDP',
    ])
asm.append('END')
(root / 'native' / 'proxy.def').write_text('\n'.join(defs)+'\n', encoding='ascii')
(root / 'native' / 'proxy.asm').write_text('\n'.join(asm)+'\n', encoding='ascii')
(root / 'native' / 'proxy_exports.inc').write_text('\n'.join(entries)+'\n', encoding='ascii')
print(f'Generated {len(symbols)} forwarding thunks')
