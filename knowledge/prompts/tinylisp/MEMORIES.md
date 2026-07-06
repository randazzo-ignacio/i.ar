# tinylisp Agent Memories

## 2026-07-06 -- Project Inception
- tinylisp project born from a conversation with the Nacho agent about learning CL
- Evolved from "CL compiler" to "portable metacircular Lisp with self-managed memory"
- Key insight: kernel only needs arrays + arithmetic + char I/O; everything else is Lisp
- v0.1 pilot implementation built in ~500 lines of C
- ALPHA_SPEC.md written documenting v0.1 as-is
- DESIGN_NOTES.md captures full architecture and reasoning
- KERNEL_SPEC.md and KERNEL_REF.md drafted (abstract + reference separation)
- Hardware path identified: kernel implementable in Verilog for FPGA/ASIC
- Nacho's spec philosophy: mathematical/structural style, encoding as parameter
- Nacho prefers build-first, spec-second approach
- Three-part spec structure agreed: Kernel, Language, Standard Library

## Key Files
- /root/.emacs.d/tinylisp/tinylisp.c -- v0.1 pilot (C, ~500 lines)
- /root/.emacs.d/tinylisp/ALPHA_SPEC.md -- v0.1 spec
- /root/.emacs.d/tinylisp/DESIGN_NOTES.md -- architecture and reasoning
- /root/.emacs.d/tinylisp/KERNEL_SPEC.md -- abstract kernel spec draft
- /root/.emacs.d/tinylisp/KERNEL_REF.md -- reference implementation params

## Open Items
- NAS backups still not set up (Nacho is aware, git used as stopgap)
- v0.1 has no GC, no TCO, no type predicates (by design, for pilot)
- Next steps: play with v0.1, find the walls, then design v0.2
- SysML integration ideas mentioned but deferred (separate concern)
