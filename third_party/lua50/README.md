# Test interpreter source

This is the unmodified Lua 5.0.3 source archive from
https://www.lua.org/ftp/lua-5.0.3.tar.gz, SHA-256
`1193a61b0e08acaa6eee0eecf29709179ee49c71baebc59b682a25c3b5a45671`.

It is used only by remote compatibility tests, under the MIT license reproduced
in `COPYRIGHT` and in the archive. It is not shipped with the game plugin.
Keeping the verified archive avoids repeated test failures when the upstream
download server cannot be reached from a Windows runner.
