# ignisp Agent Memories

## Design Philosophy

### The Three-Layer Architecture (2026-07-10)

The architecture is: ignisp (Lisp) → lambda calculus (IR) → reducer (hardware abstraction).

This is the standard compiler pipeline (source → IR → machine), with lambda calculus as the IR instead of a custom bytecode. This is not novel — GHC does this (Haskell → Core → STG → machine), Turner's combinator reduction did this, the Reduceron (FPGA) did this.

The unusual choice is **stopping at lambda calculus and running it directly** instead of compiling further to a faster target. This trades performance for portability and simplicity. Every mainstream system compiles *away from* lambda calculus; ignisp chooses to *stay there*.

**Why this is a good bet for ignisp:** In 50 years, the performance landscape will be unrecognizable. A custom bytecode IR designed for today's hardware will be irrelevant. Lambda calculus will still be lambda calculus. The bet is that permanence of the computational model matters more than current execution efficiency.

**The escape hatch:** If performance is ever needed, ignisp can be transpiled to whatever target language exists. The lambda calculus IR doesn't prevent that — it enables it, because lambda calculus is the most studied compilation target in CS.

**The real risk is not the architecture — it's the bootstrap.** Getting from "lambda calculus reducer in C" to "a usable Lisp" is a lot of work. Church-encoded cons cells are slow. Church-encoded strings are slower. The reader on a naive reducer might take seconds to parse a small file. The architecture is a 50-year decision; the bootstrap is a 3-month sprint. They have different risk profiles. The Python bootstrap must be quick and dirty — get ignisp running, even if slow, then iterate.

### Immutability (2026-07-10)

ignisp is fully immutable. No setq, no boxes, no mutable cells in any layer. State is threaded through recursion. Macros (`->`, `loop`, `with-state`) provide ergonomic syntax that expands to immutable code. If shared mutable state is ever needed (e.g., concurrency), boxes can be added then. YAGNI.

### Nacho's "Why Has No One Built This" Instinct

Nacho questions whether his ideas are novel or have fundamental flaws that prevented others from doing them. This is one of his best traits — it saves him from rabbit holes. The answer for the three-layer design: people have built it, but they all kept going past lambda calculus to something faster. Nacho is choosing to stop there. That's the bet.

### Nacho's Communication Style

- Don't over-explain terms he's unfamiliar with. He can search for them. Throwing around terms like Y combinator, Z combinator, omega combinator casually is fine — he finds it funny, not confusing.
- He trades performance for simplicity deliberately. "If I had built this 10 years ago, would it be viable today?" is his framing, not "how fast is this."
- He wants to discuss wild ideas to check his long-term enthusiasm. These discussions are valuable even when the conclusion is "not for a long time." They validate the architecture.

## Architecture Decisions Log

| Decision | Date | Rationale |
|----------|------|-----------|
| Three layers (not metacircular) | 2026-07-10 | Metacircular has no layer boundary to optimize against. Bootstrap paradox. Nacho would never optimize the core. |
| Lambda calculus as Layer 2 (not bytecode) | 2026-07-10 | Permanence. Lambda calculus outlives hardware. Bytecode formats are ephemeral. |
| Eager evaluation (not lazy) | 2026-07-10 | Forces performance honesty. Simpler to implement. No space leaks. Aligns with Lisp tradition. |
| Z combinator (no define in Layer 2) | 2026-07-10 | Purity. Layer 2 has no special forms. define is a Layer 3 feature compiled to Z. |
| Layer 2 not human-writable | 2026-07-10 | Compiler target, not a language for humans. Bootstrap via Python script. |
| No arrays in any layer | 2026-07-10 | Simplicity over performance. Everything Church-encoded. |
| Fully immutable (no setq, no boxes) | 2026-07-10 | State threaded through recursion. Macros for ergonomics. YAGNI for mutation. |
| Python bootstrap (not fat C kernel) | 2026-07-10 | Generate Layer 2 code from Python, test on Python reducer, then port to C. Cleaner, more testable. |
## Session Notes

### 2026-07-10 (late night session)
- Major architecture session: moved from metacircular to three-layer design
- Layer 2 = lambda calculus + ints + IO (not bytecode, not Lisp)
- Decided: eager evaluation, Z combinator (no define in Layer 2), no arrays, fully immutable
- Bootstrap: Python script generates Layer 2 code, not a fat C kernel
- Performance estimates produced: 5-50x slower than Python for typical programs, 100x worst case (strings, random access). No exponential operations. Nacho is comfortable with this.
- Discussed distributed lambda reduction: research topic, but Layer 2 unchanged. Only Layer 1 would need rewriting. Not a near-term goal.
- Nacho is in exploratory phase. Conversations are documentation gathering. He will rewrite things by hand. Don't rush to specs or code yet.
- Created IDEAS.md with full session summary. Updated DESIGN_NOTES.md with all decisions.
- Nacho's working style note: he never had anyone to talk to about these ideas and always kept them in his head. Starting to pour them into files. Be patient, let the exploration finish before pushing to implementation.