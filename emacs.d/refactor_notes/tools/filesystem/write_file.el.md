# tools/filesystem/write_file.el -- Annotation

## What It Does

Creates or overwrites a file. Checks file guard first. If file is open in a buffer, writes to buffer and saves (with read-only and modified-p checks). If not in a buffer, uses atomic write (temp file + rename). Creates parent dirs. Audit logs on success.

## What's Good

- **Buffer-aware write is the right complexity.** `find-buffer-visiting` prevents stale buffer overwrites. Real problem, correct solution.
- **Atomic write for non-buffer files.** `make-temp-file` + `rename-file` is atomic on POSIX. Prevents partial writes.
- **`buffer-read-only` and `buffer-modified-p` checks.** Prevents data loss. Good safety.
- **`iar--with-suppressed-save-hooks`.** Prevents format-on-save etc. from mutating content. Correct.
- **`make-directory` with parents.** Creates parent dirs if needed. Convenient for agents.
- **Guard reason returned to agent.** Agent sees the explanation, not generic "access denied." Better for self-correction.
- **Explicit `require` statements.** `iar-file-guard`, `iar-audit-log`, `iar-utils`. Dependencies are explicit, no implicit load-order reliance. Good example for the GUIDELINES.md rule.

## Issues Found

### 1. Audit log only on success [ARCHITECTURE -- ALREADY TRACKED]
**Problem:** Failed writes (guard block, read-only buffer, modified buffer) are not audited. User wants all tool calls logged with return code/status -- if an LLM is wasting half its tool calls on unsuccessful writes, that's a signal to investigate.
**Fix:** Centralize in the tool call layer. Every tool call is audited with status (success/failure). Individual tools don't implement audit logging. Already tracked.

### 2. `my-gptel--audit-log-write` legacy prefix [NAMING -- ALREADY TRACKED]
**Fix:** Already tracked.

### 3. `make-temp-file "gptel-write-"` prefix [NAMING -- MINOR]
**Problem:** Temp file prefix is `gptel-write-`. Should be `iar-write-` or similar.
**Fix:** Rename during refactor.

### 4. `condition-case` wraps success path but not guard check [FLAG FOR REFACTOR DISCUSSION]
**Problem:** If `iar--guard-check-write` throws (e.g., `file-truename` fails), the error propagates uncaught. The guard has its own `condition-case` on `file-truename`, but if it fails, the tool returns a raw error instead of a formatted one.
**Note:** Flag for refactor discussion. The right error handling pattern will be more apparent after all files are reviewed. May be resolved by the tool call layer centralizing error handling.

### 5. `add-to-list 'gptel-tools` + `require 'gptel` [ARCHITECTURE -- ALREADY TRACKED]
**Fix:** Already tracked -- tool call layer abstraction.

### 6. `iar--mygptel--` prefix [NAMING -- ALREADY TRACKED]
**Fix:** Already tracked.

## Patterns to Watch

- **Error messages stay in code.** System messages (error strings, success strings) are not prompt text. Separating them would create unnecessary complexity. GUIDELINES.md rule: error/success messages stay in code, prompt templates go in prompt files.
- **Buffer-aware vs. atomic write pattern.** Two code paths depending on whether the file is open in a buffer. Watch if other write tools (append, replace) follow the same pattern consistently.
- **Explicit requires as the right pattern.** This file does it right -- `require` for every dependency. Compare with other files that use implicit load-order reliance.