option casemap:none
EXTERN FakeRustSleep:PROC
.code
SimulationStep PROC FRAME
  sub rsp, 28h
  .allocstack 28h
  .endprolog
  xor ecx, ecx
  mov edx, 25000000
  call FakeRustSleep
  nop
  add rsp, 28h
  ret
SimulationStep ENDP
END
