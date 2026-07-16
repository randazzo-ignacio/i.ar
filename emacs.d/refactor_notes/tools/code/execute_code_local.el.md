# tools/code/execute_code_local.el -- Annotation

## What It Does

Runs bash commands asynchronously in the container. Returns result via callback when process completes. Timeout kills hung processes. Optional output sanitization for CTF/external ops. Audit logs every execution with exit code.

## What's Good

- **Async with callback.** Emacs stays responsive. gptel's FSM isn't blocked. Correct design.
- **`:connection-type 'pipe`.** No pty. Programs detect non-interactive mode, skip pagers/colors/prompts. No env var patches needed. Documented.
- **Sanitize flag captured at call time.** Process sentinels run in unpredictable buffer context. Capturing at call time is correct. Same insight documented in output-sanitizer.el.
- **Timeout with process kill.** `run-with-timer` + `delete-process`. `timed-out` flag checked in sentinel for correct message.
- **Three result cases.** Timeout, non-zero exit, normal. Distinct messages. Agent can distinguish failure modes.
- **Audit log with exit code.** -1 for timeout, 0 for success, actual code for failure. Good for analysis.
- **`condition-case` in tool lambda.** `make-process` failures caught and formatted for the agent. Core function can signal normally for direct callers (tests). Good separation.
- **Buffer cleanup.** `kill-buffer` on completion, on error, guarded by `buffer-live-p`. No leaked buffers.

## Issues Found

### 1. Tool description lists hardcoded available commands [DOC]
**Problem:** Description lists "bash, dig, nmap, openssl, python3, jq..." -- if container image changes, description is stale. Also implies these are the ONLY available commands.
**Fix:** Change description to something like "Execute bash/shell commands in a Linux environment. Any standard Linux command is available." If a command isn't available, add it to the container. Don't hardcode a list that implies limitation.

### 2. `bound-and-true-p` for sanitize flag may be redundant [CLEANUP]
**Problem:** `require 'iar-output-sanitizer` guarantees the flag is bound. `bound-and-true-p` adds a `boundp` check that's technically unnecessary.
**Note:** Minor. `bound-and-true-p` also checks truthiness in one call, so it's efficient. Leave as-is or simplify to just the variable reference. Decide during refactor.

### 3. Buffer name ` *gptel-async-shell*` [NAMING -- ALREADY TRACKED]
**Fix:** Rename to `iar-` prefix. Already tracked.

### 4. Legacy prefixes [NAMING -- ALREADY TRACKED]
**Fix:** Already tracked.

### 5. `add-to-list 'gptel-tools` + `require 'gptel` [ARCHITECTURE -- ALREADY TRACKED]
**Fix:** Already tracked -- tool call layer abstraction.

## Patterns to Watch

- **Async tool pattern.** `:async t` in `gptel-make-tool`, function takes callback as first arg, calls callback with result. Different from sync tools (list_directory, read_file, etc.). The tool call layer needs to handle both sync and async tools.
- **Two-layer error handling.** Core function signals, tool lambda catches and formats. Allows core function to be called directly (tests) with normal signaling, while tool provides agent-friendly errors. Good pattern for complex tools.
- **Closure-heavy sentinel.** Six variables captured in the sentinel lambda. Dense but correct. Watch if other async tools need the same pattern -- may warrant a helper.