# init.el -- Annotation

## What It Does

Entry point for the entire system. Defines directory constants, sets up load-path, loads all modules in explicit dependency order, then auto-discovers dynamic modules. No logic, no behavior -- pure wiring.

## Structure

1. `lexical-binding: t` (file-local) + `load-prefer-newer t` (prevents stale .elc shadowing source)
2. 14 `defconst` directory paths, all chained off `user-emacs-directory`
3. `load-path` setup via `dolist` + `add-to-list` for cross-module `require` resolution
4. Manual `load` calls in strict dependency order:
   - metaconfig/parameters.el (via `load-file`, not `load` -- see issues)
   - shared utilities (iar-utils, iar-agent-utils)
   - Self-modification env var check (before file-guard loads)
   - Core modules (locale, package-setup, ui-cleanup, evil, gptel-setup, gptel-compat, mount-awareness, tool-result-truncation)
   - Security modules (output-sanitizer, file-guard, audit-log, loop-guard)
   - Tools (prompt-loader, filesystem, code, tasks, notify, git)
   - Agent modules (loader, knowledge, delegate, reload, memory, cycle)
   - Debug modules (buffer-monitor, request-logger, fsm-tracer)
   - Session (quit)
   - Auto-discovery of init.d/dynamic/*.el
5. No `provide` statement -- intentional, init.el is a script not a library

## What's Good

- **Comments are excellent.** Every load has a comment explaining what and why. Dependency ordering is documented inline. Rare and valuable.
- **Explicit load order.** Single source of truth for what loads and when. No magic, no implicit discovery (except dynamic/ which is intentional).
- **No error handling.** Intentional -- fail fast, fail loud. Better to not start Emacs than to miss a load failure in the minibuffer. Good for development.
- **Auto-discovery at the end.** Clean escape hatch for darwin-created modules. Promotion path is documented in comments.

## Issues Found

### 1. gptel-specific/ lives outside init.d/ [STRUCTURAL]
**Location:** gptel-specific dir added inline during load sequence, not with other defconsts at top.
**Problem:** Bolted on rather than designed in. `gptel-specific/` lives at `user-emacs-directory/gptel-specific/` instead of `init.d/gptel-specific/`. Its load-path entry is added inline, breaking the pattern.
**Fix:** Move `gptel-specific/` inside `init.d/`. Add defconst + load-path entry with the other subdirs. Update load call path.

### 2. parameters.el lives outside emacs.d/ [STRUCTURAL]
**Location:** `metaconfig/parameters.el` loaded via `load-file` instead of `load`.
**Problem:** Original idea was that parameters.el should be visible to users without inspecting init files. But it IS an elisp file -- it belongs inside emacs.d. The `load-file` vs `load` inconsistency stems from this placement. `metaconfig/` is outside the `init.d/` directory structure and isn't added to `load-path`.
**Fix:** Move `parameters.el` inside `emacs.d/` (e.g., `init.d/metaconfig/` or just `emacs.d/parameters.el`). Use `load` instead of `load-file` for consistency. Update `metaconfig/gptel.el` reference path in iar-gptel-setup.el.

### 3. iar-tool-guard.el not loaded in init.el [BUG]
**Problem:** `iar-tool-guard.el` (unknown tool blocking) is not in init.el's load sequence. It's loaded by `iar-delegate-tool.el` instead. This is wrong -- tool-guard is a security module and should be loaded in init.el with the other security modules.
**Fix:** Add explicit `load` for `iar-tool-guard.el` in the security section of init.el. Remove the load from `iar-delegate-tool.el` (replace with `require` if needed).

### 4. iar-prompt-loader.el comment categorization [DOC]
**Problem:** `iar-prompt-loader.el` is loaded under the "Tools modules" comment block but it's an agent module, not a tool. Comment says "Prompt loader -- load prompt templates" but it's categorized as a tool.
**Fix:** Move the load call to the agent modules section, or fix the comment to reflect that it's a shared dependency loaded before the agent section.

## Patterns to Watch

- **defconst directory paths:** User believes no other module references these constants directly. Watch for references during review -- if confirmed, they're file-local constants that could be `let`-bound or just inlined.
- **load vs require:** Everything uses `load` (path-based) not `require` (symbol-based). This means load order is controlled by init.el, not by dependency declarations. Works but means init.el must know the full dependency graph.