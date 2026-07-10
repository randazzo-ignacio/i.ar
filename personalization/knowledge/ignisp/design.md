# ignisp Language Design

## What ignisp Is

ignisp is a minimal Lisp derivative designed for maximum portability and longevity. It is not a product, a library, or a learning exercise. It is a life project -- a computational environment designed to survive decades and be rebuildable on any platform that exists or will exist.

The name comes from Ignacio (Nacho's name) + Latin *ignis* (fire). Fire is the spark that bootstraps everything -- the reducer is the spark, the language is the flame.

## Core Philosophy

- **The spec is permanent. The implementation is disposable.** In 50 years, Layer 1 may have been rewritten 20 times in 20 host languages. The spec is what stays constant.
- **Three layers, three concerns.** Hardware abstraction (disposable), computational abstraction (permanent), and the language (permanent).
- **Absolute portability over performance.** 100x slowdown is acceptable. The Layer 1 reducer must be small enough to rewrite in a day in any host language.
- **Force performance honesty.** The language should not hide computational cost behind lazy evaluation or runtime optimizations.
- **KISS and DRY.** Every added complexity must justify itself.
- **No hard dependencies.** If a dependency is small enough to rewrite in a day, it's acceptable. Otherwise, eliminate it.
- **Fully immutable.** No mutation anywhere -- no setq, no boxes, no mutable cells. State is threaded through recursion.
- **The 50-year horizon.** A language to grow with, modify at will, and rebuild on any future platform.

## Architecture: Three-Layer Design

```
Layer 3: IGNISP -- THE LANGUAGE (permanent)
         A normal Lisp. Built on Layer 2.
         Reader, eval, macros, cons cells, stdlib, object system.
         This is where the programmer lives.
         ↓ compiled to
Layer 2: COMPUTATIONAL ABSTRACTION (permanent, the "assembly")
         Lambda calculus + native integers + I/O.
         Not human-writable. A compiler target.
         Spec frozen once stable.
         ↓ executed on
Layer 1: HARDWARE ABSTRACTION (disposable, rewrite per platform)
         A lambda calculus reducer. Implemented in C today,
         Python tomorrow, FPGA someday.
         Rewriting this is the ONLY work needed to port ignisp.
```

### Why three layers?
The metacircular approach (two layers) collapses the computational core and the language into one thing. Three layers gives each concern its own home and its own spec. Layer 2 is the boundary -- it has its own spec, its own identity. The bootstrap is clean: Layer 2 is simple enough to generate from a script. No chicken-and-egg.

### Why lambda calculus for Layer 2?
It is permanent (studied 80+ years, will outlive every hardware architecture). It is minimal (three constructs: variables, abstraction, application, plus native integers and I/O). It separates computation from hardware. It maps to any computational substrate (CPUs, GPUs, FPGAs, distributed systems). It is the honest answer to "what is the minimal computational substrate?"

The unusual choice is **stopping at lambda calculus and running it directly** instead of compiling further to a faster target. This trades performance for portability and simplicity. Every mainstream system compiles *away from* lambda calculus; ignisp chooses to *stay there*.

## What Each Layer Contains

**Layer 1 (Hardware Abstraction) -- the reducer:**
- Representation of lambda terms (variables, abstractions, applications)
- Native integer values and operations (+, -, *, /, <, >, =)
- Character I/O (read-char, write-char)
- Beta reduction engine (eager / applicative order)
- Memory allocation and GC
- NO mutation. NO arrays. Pure functional.

**Layer 2 (Computational Abstraction) -- the permanent core:**
- Lambda abstraction: λx.M
- Application: M N
- Native integer operations (from Layer 1)
- I/O primitives (from Layer 1)
- Church-encoded data: booleans, pairs, lists
- Z combinator for recursion (no =define= in Layer 2)
- Thunked conditionals (no =if= special form in Layer 2)
- The ignisp compiler, reader, eval, and printer
- NO mutation. NO arrays. NO setq. Pure functional.

**Layer 3 (Ignisp) -- the language:**
- S-expression syntax (what the programmer writes)
- Special forms: if, quote, lambda, let, define, defmacro, begin (NO setq)
- Macros and macroexpansion
- Cons cells, strings, symbols, closures (Church-encoded in Layer 2)
- Standard library: list ops, string ops, math, I/O
- Ergonomic macros: =->= (thread-first), =loop=/=for= (comprehensions), =with-state=
- Object system (CLOS-like, built on closures)
- Fully immutable. No mutation anywhere.

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Eager evaluation (applicative order) | Simpler to implement. No space leaks. Forces performance honesty. |
| Z combinator for recursion | In pure lambda calculus with eager eval, functions can't refer to themselves by name. Z combinator solves this. Layer 2 is not human-writable -- the compiler handles it. |
| Church encoding for all data | Cons cells, lists, booleans -- all Church-encoded. No arrays in any layer. Simplicity and purity over performance. |
| Layer 2 is not human-writable | Mechanically generated by the compiler. Humans write ignisp (Layer 3). |
| Fully immutable language | No setq, no boxes, no mutable references. State threaded through recursion. Macros provide ergonomics. |
| GC is a Layer 1 concern | The reducer owns all term memory. Mark-sweep over the term graph. Layer 2 has no concept of memory management. |
| Python bootstrap | Generate Layer 2 code from Python, test on Python reducer, then port to C. Cleaner than a fat C kernel. |

## Memory Management

- **Mark-sweep GC chosen** over Rust-style ownership (restricts dynamic features) and reference counting (cycles leak, more code than mark-sweep for less benefit).
- **Phase 1 (current): bump allocator, no GC.** malloc everything, never free. Acceptable for bootstrap and short programs.

## Bootstrapping

The bootstrap problem: Layer 2 is not human-writable. The compiler (Layer 3 to Layer 2) is itself written in... what? If written in ignisp, it needs to be compiled. Chicken-and-egg.

Solution: use a Python script as the bootstrap compiler.

1. Python implements a minimal lambda calculus reducer (Layer 1 in Python -- throwaway)
2. Python generates Layer 2 code that implements the ignisp core (reader, eval, basic stdlib)
3. Test the generated Layer 2 code on the Python reducer
4. Write Layer 1 in C (the real reducer, ~300-500 lines)
5. Run the same Layer 2 code on the C reducer
6. ignisp is now running. From this point, all development happens in ignisp (Layer 3). The Python script is discarded.

Bootstrap phases:
- Phase 0: Spec (1-2 weeks)
- Phase 1: Bootstrap in Python (2-4 weeks)
- Phase 2: C Reducer (1-2 weeks)
- Phase 3: ignisp Core in ignisp (2-4 weeks) -- self-hosting
- Phase 4: Standard Library (ongoing)
- Phase 5: GC (1-2 weeks)
- Phase 6: Transpiler (long-term)
- Phase 7: Hardware (long-term dream) -- implement reducer in Verilog, run on FPGA

## Current State

A pilot C implementation exists at `/var/home/nacho/repos/ignisp/ignisp.c` (~500 lines). It is a throwaway to see a Lisp working end-to-end. It does NOT reflect the final three-layer architecture -- it is a traditional tree-walking interpreter with cons cells in C, setq, and mutation.

The pilot includes: reader with strings/numbers/symbols/comments/quote/dotted pairs, printer, evaluator with 5 special forms and 17 primitives, macros with rest parameters, lexical closures, recursion, arrays, error recovery, REPL.

Files in `/var/home/nacho/repos/ignisp/`:
- `ignisp.c` -- pilot implementation (throwaway)
- `DESIGN_NOTES.md` -- architecture and reasoning (PRIMARY SOURCE OF TRUTH)
- `ALPHA_SPEC.md` -- spec for pilot (historical, outdated)
- `KERNEL_SPEC.md` -- abstract kernel spec draft (needs updating)
- `KERNEL_REF.md` -- reference implementation parameters draft (needs updating)
- `README.md` -- project README

## Performance Estimates

5-50x slower than Python for typical programs, 100x worst case (strings, random access). No exponential operations. Nacho is comfortable with this -- the trade is performance for permanence.

## Nacho's Working Style (for agents working on ignisp)

- **Chaotic-creative.** Ideas come fast, connections happen sideways. Don't fight it, but don't let it run unchecked.
- **Needs the full mental picture before writing code.** Designs through conversation. This is not stalling -- it's how his creative process works.
- **Build-first, spec-second.** "First make it work, then make it work well." The pilot exists. The spec follows.
- **Perfectionism that paralyzes.** Wants everything perfect from the start. Push to ship ugly and refine.
- **Leverage collaboration.** Don't just advise -- build with him. Write code, write specs, write tests. He supervises and edits.
- **Remind him about backups.** If the ignisp files are lost, the 50-year project dies in year one.