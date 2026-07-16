# tools/code/check_elisp.el -- Annotation

## What It Does

Checks .el files for syntax errors, unbalanced parens, and byte-compilation warnings. Two-phase: `check-parens` in a temp buffer, then `byte-compile-file` with a temp .elc destination. Source file is never touched. Returns a diagnostic report.

## What's Good

- **Two-phase check is the right approach.** Parens first (fast, structural), then byte-compile (slower, semantic). Agent gets both kinds of feedback.
- **`unwind-protect` for temp file cleanup.** Temp .elc always deleted, even on crash. No artifacts.
- **`byte-compile-dest-file-function` redirect.** Prevents .elc next to source. Clean.
- **Compile log cleared before and after.** Before: only this file's warnings. After: clean for next call.
- **Source file never modified.** Temp buffer + temp .elc. Read-only to source.
- **`emacs-lisp-mode` in temp buffer.** Needed for `check-parens` syntax table. Correct.
- **Validation before work.** File exists + `.el` extension checked first. Fail fast.
- **`string-match-p "\\S-"` for non-whitespace check.** Only reports compile log with actual content.

## Issues Found

### 1. Tool should be async by default [GUIDELINES]
**Problem:** Tool is synchronous. `byte-compile-file` is fast enough now, but tools should be async by default unless there's a specific reason to be sync.
**Fix:** Make async. GUIDELINES.md rule: **tools are async by default. Sync only when there's a clear requirement** (e.g., the tool must complete before the next line of code runs, or the operation is trivially fast and async overhead isn't worth it).

### 2. `make-temp-file "elc-check-"` prefix [NAMING -- MINOR]
**Problem:** No `iar-` prefix.
**Fix:** Rename to `iar-elc-check-` during refactor.

### 3. Naming convention distinguishes gptel-hooking from pure utility [NOTE]
**Problem:** `iar--check-parens-in-buffer` uses `iar--` (pure utility), `iar--mygptel--tool-check-elisp` uses `iar--mygptel--` (hooks into gptel). This distinction is intentional -- pure utility functions don't hook into gptel.
**Note:** With the tool call layer, the distinction disappears. All functions become `iar--`. The `mygptel--` prefix was the signal for "this hooks into gptel" -- after the abstraction, nothing hooks into gptel directly except the tool call layer itself.

### 4. `byte-compile-warnings t` (all warnings) [NOTE]
**Problem:** All warnings enabled, including style warnings. May produce noise on valid code with minor style issues.
**Note:** For a self-modifying system where darwin writes code, strict is probably correct. Decide during refactor if the warning level should be configurable.

### 5. No audit logging [ARCHITECTURE -- ALREADY TRACKED]
**Fix:** Centralized in tool call layer. Already tracked.

### 6. `add-to-list 'gptel-tools` + `require 'gptel` [ARCHITECTURE -- ALREADY TRACKED]
**Fix:** Already tracked -- tool call layer abstraction.

## Patterns to Watch

- **Tools async by default.** GUIDELINES.md rule. Sync only with clear justification. check_elisp is currently sync but should be async.
- **Pure utility vs. gptel-hooking naming.** `iar--` for utilities, `iar--mygptel--` for gptel hooks. After tool call layer, all become `iar--`. The distinction was a workaround for the lack of abstraction.
- **`push` + `nreverse` idiom.** Consistent across mount-awareness, check_elisp, and others. Standard Lisp list building.