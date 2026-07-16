# security/iar-loop-guard.el -- Annotation

## What It Does

Detects and breaks repetitive tool call loops. Soft threshold (default 3): blocks the call and sends a correction message. Hard threshold (default 6): stops the entire request. Uses a buffer-local history ring to track recent calls by (tool-name . args-md5) signature.

## What's Good

- **Soft/hard threshold model is well-designed.** Soft gives the model a chance to self-correct. Hard stops it if it doesn't listen.
- **History never cleared between turns.** Comment explains: "loops can span turns, which is exactly what happened with darwin (350+ identical calls across continuation prompts)." Real bug, documented fix.
- **`final-hard` always > `effective-soft`.** Misconfigured thresholds get corrected. Model always gets at least one soft warning before hard stop.
- **Defense-in-depth on threshold validation.** `:safe` predicates + runtime validation. Consistent with file-guard and audit-log patterns.
- **Uses prompt templates.** `loop_soft_block.org` and `loop_hard_stop.org` -- correction messages externalized to prompt files. This is the pattern we want everywhere.
- **Block count uses actual count, not estimate.** More accurate, handles intervening calls and threshold reconfiguration.
- **`message` logging on both soft and hard.** Visible in `*Messages*` for debugging.

## Issues Found

### 1. KEY INSIGHT: i.ar needs its own tool call layer [ARCHITECTURE -- MAJOR]
**Problem:** This module hooks into `gptel-pre-tool-call-functions` to intercept tool calls. Every module that needs to observe/intercept tool calls (loop guard, tool guard, truncation, debug modules) hooks into gptel's internals or gptel's hooks. This is the root cause of the gptel coupling.
**Fix:** Build `iar--gptel--tool-call` (or similar) -- i.ar's own tool call mechanism that hooks into gptel's FSM. This is the SINGLE integration point with gptel. Everything else (loop guard, tool guard, truncation, debug modules) hooks into i.ar's tool call layer, not gptel's. The compat layer (`iar-gptel-compat.el`) becomes unnecessary because the abstraction is at the right level -- not wrapping individual gptel symbols, but inserting one integration point.
**Impact:**
- `iar-gptel-compat.el` is removed (already tracked)
- `gptel-pre/post-tool-call-functions` hooks are replaced by i.ar's own hooks
- Loop guard, tool guard, truncation, debug modules all hook into i.ar's tool call layer
- The `--gptel` / `--mygptel--` prefixes are dropped from all functions (they're no longer "hooking into gptel")
- FSM access stays gptel's (our tool call layer is the only thing that touches it)

### 2. `my-gptel--` prefix is legacy [NAMING -- ALREADY TRACKED]
**Problem:** All functions and variables use `my-gptel--` prefix. With the tool call abstraction (issue 1), these become `iar--` functions.
**Fix:** Rename after the tool call layer is built.

### 3. `declare-function` without `require` [CONVENTION -- ALREADY TRACKED]
**Problem:** `iar--load-prompt` is declared but `iar-prompt-loader` is not required.
**Fix:** Add `require`. Already tracked as GUIDELINES.md rule.

### 4. `md5` for args hashing [PERFORMANCE]
**Problem:** `md5` is cryptographic overhead for a comparison hash. Emacs has `sxhash` which is faster and doesn't require string conversion.
**Fix:** Replace `md5` with `sxhash`. Simpler and faster.

### 5. `cl-subseq` for ring trimming [PERFORMANCE -- NOTE]
**Problem:** Creates a new list on every push when history exceeds max size. O(n) where n is current history length. A ring buffer would be O(1).
**Note:** For max size 20, this is negligible. Compare implementations during refactor and keep the simpler one.

### 6. `loop-args-sig` bounded print level/length [FLAG FOR REFACTOR DISCUSSION]
**Problem:** `print-level 3` and `print-length 200` mean two different args that differ only beyond level 3 or char 200 produce the same hash. In practice tool args are flat lists, so this is fine.
**Note:** User doesn't see the issue but wants to discuss during refactor. Flag for Day 3 discussion.

## Patterns to Watch

- **The tool call layer is the root abstraction.** This file surfaced the insight: every gptel coupling stems from hooking into gptel's tool call mechanism. The fix is not wrapping individual symbols (compat layer) but inserting one integration point (i.ar's tool call). This is the most important architectural decision of the refactor.
- **Prompt templates externalized.** This module does it right -- correction messages are in `.org` files, not elisp. This is the pattern we want everywhere. GUIDELINES.md rule.
- **Defense-in-depth on config validation.** `:safe` at file-local level + runtime validation in function. Consistent across file-guard, audit-log, and loop-guard. GUIDELINES.md rule.