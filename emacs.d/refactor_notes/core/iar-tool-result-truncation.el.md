# core/iar-tool-result-truncation.el -- Annotation

## What It Does

Intercepts tool results before they enter the conversation buffer and truncates them if they exceed `iar-tool-result-max-chars`. Middle-truncation: keeps first half and last half, replaces middle with a notice. The fix for token bloat -- a 38MB tool result would cost 9.6M tokens on the next send without this.

## What's Good

- **The header comment is a case study.** Explains the mechanism, why it works, and explicitly contrasts with the failed compression approach. "We intercept at the tool function level, not in the buffer after the fact." Institutional knowledge preserved.
- **The advice function is pure.** No state, no side effects, no buffer manipulation. Receives a string, returns a string. Easy to test, easy to reason about.
- **Uses the compat layer.** `iar-gptel-advise-process-tool-call` instead of raw `advice-add` on a gptel internal. If gptel 1.0 changes the internal, only the compat layer needs updating.
- **Middle-truncation is the right strategy.** Start has headers/context, end has error messages/final output. Middle is usually repetitive bulk.
- **Self-installing.** Load the file, it works. No init.el wiring beyond the load call.

## Issues Found

### 1. `defvar` should be nil, not 10000 [CONVENTION]
**Problem:** `defvar iar-tool-result-max-chars 10000` sets a default value. Other forward-declared variables in the codebase use `(defvar iar-foo nil)` -- nil means "not yet defined, owned by config file." Setting 10000 here is inconsistent with the pattern.
**Fix:** Change to `(defvar iar-tool-result-max-chars nil)`. The defcustom in parameters.el owns the real default.

### 2. `boundp` check is redundant [CLEANUP]
**Problem:** `(if (boundp 'iar-tool-result-max-chars) iar-tool-result-max-chars 10000)` -- the defvar at the top of the file already guarantees the variable is bound. parameters.el is guaranteed loaded before any init.d module. The `boundp` check and fallback to 10000 are dead code.
**Fix:** Remove the `boundp` check. Reference `iar-tool-result-max-chars` directly. Convention: parameters.el is always loaded first, variables are always bound.

### 3. Runtime mutability of `iar-tool-result-max-chars` [DISCUSS DURING REFACTOR]
**Problem:** Currently the value is set at load time by parameters.el defcustom. If a user changes it via Customize at runtime, the truncation function picks up the new value (it reads the variable at call time, not at load time). This is actually useful -- you might want to increase the limit mid-session for a specific task. But the defense-in-depth checks (integerp, positive, nil) were added to handle this runtime flexibility safely.
**Question:** Should this parameter be runtime-mutable? If yes, keep the runtime validation (but remove the boundp). If no, simplify further. User is leaning toward runtime-mutable being useful for this specific parameter. Discuss during refactor.

### 4. Truncation notice is hardcoded English [STRUCTURAL -- ALREADY TRACKED]
**Problem:** "[... truncated: %d total chars, kept first %d and last %d ...]" is prompt-adjacent text in elisp code. Same pattern as mount-awareness.el and delegation-result-marker.
**Fix:** Move to prompt/marker files. Already tracked as a GUIDELINES.md rule: prompt text does not belong in elisp code.

### 5. Compat layer API and advice signature [FLAG FOR REFACTOR REVIEW]
**Problem:** `iar-gptel-advise-process-tool-call` takes `:around` keyword + function symbol. The advice signature `(orig-fun fsm tool-spec tool-call result)` mirrors gptel's internal `gptel--process-tool-call` argument list. Questions: Does the compat layer normalize the signature, or pass through raw? If gptel changes the arg list, does the compat layer handle it?
**Note:** Defer decision until after reviewing `gptel-specific/iar-gptel-compat.el` (next file in the sprint). Make a decision about how the compat layer should handle advice signatures after understanding the full implementation.

## Patterns to Watch

- **Forward-declaration convention:** `defvar` should be nil, not a default value. Config file owns the default. Inconsistent application of this pattern across the codebase.
- **Runtime-mutable vs. load-time-frozen parameters:** Some parameters are useful to change at runtime (like truncation limit), others are effectively immutable (like directory paths). GUIDELINES.md should distinguish: runtime-mutable parameters need runtime validation, load-time-frozen parameters don't.
- **Self-installing modules:** `(setup-function)` at the bottom of the file. Load it, it works. Clean pattern. Watch for consistency across modules.