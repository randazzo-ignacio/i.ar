# security/iar-output-sanitizer.el -- Annotation

## What It Does

Strips control characters, neutralizes fake system message wrappers, flags injection-like lines, and wraps external content in a `[SANITIZED EXTERNAL DATA]` envelope. Defense-in-depth behind the prompt injection resistance directives in base_context.org.

## What's Good

- **Threat model is documented.** Header comment explains: primary defense is prompt injection resistance in base_context.org, sanitizer is defense-in-depth. Clear layering.
- **Injection lines are flagged, not removed.** Preserves evidence while warning the AI. Correct approach.
- **Unicode zero-width character fix is documented.** Comment explains the bracket class bug and preserves the lesson.
- **Bidi controls included.** Trojan Source attacks (CVE-2021-42574) use bidi override characters. Good security awareness.
- **The comment about sentinel buffer context.** Process sentinels run in unpredictable buffer context -- flag is captured at call time. Real Emacs gotcha, documented.

## Issues Found

### 1. `my-gptel--` prefix is legacy [NAMING -- ALREADY TRACKED]
**Problem:** Every function and defconst uses `my-gptel--` prefix. Module has nothing to do with gptel.
**Fix:** Rename to `iar--` convention. Already tracked as a global pattern.

### 2. Pattern lists should be configurable, not defconst [STRUCTURAL]
**Problem:** Control patterns, injection markers, and wrapper patterns are `defconst` -- hardcoded. Adding a new injection pattern means editing this file. The "someone could weaken security" concern is a non-issue -- they'd be reducing their own security.
**Fix:** Move patterns to config files (forward-declared defcustoms). Allows extending patterns when new attack vectors are found without editing code. Each pattern category gets its own config.

### 3. Trust channel: [USER_INSTRUCTION_BEGIN]/[USER_INSTRUCTION_END] [ARCHITECTURE -- MAJOR]
**Problem:** Current approach is pattern-matching against known injection vectors. This is inherently reactive (new patterns slip through) and English-only (injections in other languages bypass flagging).
**Proposed redesign:** Wrap user instructions with `[USER_INSTRUCTION_BEGIN]` and `[USER_INSTRUCTION_END]`. The prompt tells the AI what user instructions look like. Everything else is treated as content, not instructions. This aligns with the defense strategy and makes the sanitizer's role simpler -- strip/neutralize anything that looks like an instruction marker from non-user-input sources.
**Note:** This is the "Trust Channel" idea from `future_ideas.md`. The current sanitizer becomes simpler: control char stripping stays (addresses real attack vector), but injection pattern matching is replaced by the trust channel. The `[SANITIZED EXTERNAL DATA]` envelope aligns with this -- external data is never wrapped in instruction markers.
**Impact:** Requires changes to base_context.org (prompt), gptel request construction (wrap user messages), and sanitizer (strip instruction markers from non-user sources). This is a significant architecture decision for Day 3.

### 4. `defvar-local` for sanitize flag doesn't belong here [STRUCTURAL]
**Problem:** `my-gptel--sanitize-exec-output` is defined in the sanitizer module but consumed by `execute_code_local.el`. It should live in the config files, not in the sanitizer module.
**Fix:** Move to config. The sanitizer module provides the sanitization function; the flag that controls when it's applied lives in config.

### 5. `:safe` concern on sanitize flag -- depends on execute_elisp decision [DISCUSS DURING REFACTOR]
**Problem:** A file-local variable could set the sanitize flag to nil, disabling sanitization. Whether this matters depends on the threat model, which changes significantly if `execute_elisp` is enabled (the `--enable-elisp` flag from tool_gating.md).
**Note:** Defer until the execute_elisp decision is made. If execute_elisp is enabled, the whole threat model changes -- file-local variables become a much bigger concern. If execute_elisp is not enabled, the current threat model holds and the `:safe` concern is lower priority.

### 6. Sanitize envelope appears even on clean output [NOTE]
**Problem:** `my-gptel--sanitize-external-output` wraps in `[SANITIZED EXTERNAL DATA]` even if nothing was changed. AI sees the envelope on every external output.
**Note:** With the trust channel approach (issue 3), this becomes aligned -- external data is always marked as external, regardless of whether it was modified. The envelope becomes a trust boundary marker, not a "something was sanitized" signal. Acceptable as-is, better with the trust channel.

## Patterns to Watch

- **Pattern lists as defconst vs. configurable:** Security patterns need to be extensible without code changes. Config files, not defconst. But security-sensitive configs should NOT have `:safe` -- force user interaction on file-local changes.
- **Trust channel vs. pattern matching:** The fundamental architecture decision. Pattern matching is reactive and language-specific. Trust channel is proactive and language-agnostic. The trust channel is the long-term answer; the current sanitizer is the bridge.
- **Module ownership:** Variables consumed by module A should not be defined in module B. The sanitize flag is consumed by execute_code_local, so it belongs in config, not in the sanitizer module.