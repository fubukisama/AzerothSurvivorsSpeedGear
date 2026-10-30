# Third-party sources

- AZS Speed Controller, MIT, copyright 2026 AZS Speed Controller contributors.
  Source: https://github.com/Maidenquinn/AZS-Speed-Controller
  Pinned revision: `9d1038cce89ad4da9e56558ed1978055f15049e1`.
  Its `src/hook.cpp` continuous-clock implementation was adapted into
  `native/backend.cpp` and `native/include/speed_clock.h`. Original source and
  license are retained in `third_party/azs-speed-controller/`. The fixed EXE
  hash/RVA adaptation was replaced with a fail-closed structural scanner.
- MinHook 1.3.4, BSD-2-Clause, copyright Tsuda Kageyu and contributors.
  Source: https://github.com/TsudaKageyu/minhook
  Pinned revision: `c3fcafdc10146beb5919319d0683e44e3c30d537`.
  Full source and its complete license, including HDE notices, are retained in
  `third_party/minhook/`. The native DLL statically links this library.
- Lua 5.0.3 is used only as a separately downloaded test interpreter, from
  https://www.lua.org/ftp/lua-5.0.3.tar.gz . It is not shipped with the plugin.

No game executable, game assets, saves, Microsoft system DLL, or upstream
controller binary is included in this project's distributable package.
