# shared/iar-utils.el -- Annotation

## What It Does

Four shared utilities extracted to eliminate duplication across modules. Agent name resolution, approximate token counting, audit log path construction, and a save-hook suppression macro. Loaded before all other init.d modules.

## What's Good

- **The extraction is well-motivated.** Header comment lists exactly what was duplicated and where. Not speculative DRY -- "I saw the same function in 6 files."
- **`iar--get-agent-name` is well-documented.** Docstring explains the buffer-local + global fallback pattern and WHY (debug modules run in process buffers, not conversation buffers). Critical context preserved.
- **The macro is clean.** `declare (indent 0)` for correct formatting. Binds exactly the 5 hooks that matter for save interference. No more, no less.
- **Minimal dependency.** Only `require 'subr-x`.
- **File granularity is right.** 4 utilities in one file. Splitting would mean 4 new provides for no benefit. If it grows, split by group of utils, not by function.

## Issues Found

### 1. `iar--audit-log-path` defconst computed at load time [BUG -- LATENT]
**Problem:** `defconst` computes the path from `iar-audit-path` at load time. If `iar-audit-path` is changed via Customize after load, the path is stale. It *seems* like it should work dynamically but doesn't. Bug waiting to happen.
**Fix:** Remove `iar-audit-path` (and similar base path vars) from the customizable group. They should be plain config values in config files, not Customize-tunable. In practice these paths never change after Emacs loads -- making them appear mutable is misleading.

### 2. `iar--approx-token-count` API takes chars instead of string [API]
**Problem:** Function takes an integer (char count), forcing every caller to compute `(length string)` or `(buffer-size)` before calling. Duplicates the char-counting logic at every call site.
**Fix:** Change signature to accept a string. Compute `(length string)` internally. Callers pass the string directly.

## Patterns to Watch

- **Buffer-local + global dual tracking:** `iar--current-agent-name` and `iar--current-agent-file` are set both buffer-locally and globally. The fallback chain (buffer-local -> global default -> file-derived -> "unknown") is 4 levels. Watch how other modules use this pattern -- if it appears elsewhere, consider extracting a generalized "resolve buffer-local-or-global" helper.
- **defconst for path construction:** Same `expand-file-name` chaining pattern as init.el. Consistent, but the load-time computation issue applies to any defconst that depends on a configurable variable.