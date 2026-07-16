# core/iar-gptel-setup.el -- Annotation

## What It Does

Loads gptel, applies the Ollama backend config, and optionally overrides with a local fork. 23 lines. The bridge between "package manager installed gptel" and "gptel is configured to talk to our Ollama."

## What's Good

- **The fork override is elegant.** Prepending to `load-path` before `use-package` loads is the right way to override an ELPA package. No patching, no renaming. Just path priority.
- **`setq-default` not `setq`.** Sets the default for all buffers. New gptel buffers inherit backend and model. Correct.
- **Log message on fork activation.** Visible in `*Messages*` which gptel is running. Good for debugging.
- **Three-layer validation on fork path.** Non-nil, stringp, file-directory-p. Won't break on bad input.
- **Fail fast on gptel load failure.** If gptel or its config fails, Emacs shouldn't continue. Consistent with init.el philosophy.

## Issues Found

### 1. `load-file` for gptel.el [STRUCTURAL -- ALREADY TRACKED]
**Problem:** `load-file` instead of `load` because gptel.el lives in `metaconfig/` which isn't on `load-path`. Already tracked in gptel.el annotation -- file moves to `configs/` during refactor, this becomes `load` or `require`.

### 2. Hardcoded path to gptel.el [NOTE -- DECIDE DURING REFACTOR]
**Problem:** `(expand-file-name "metaconfig/gptel.el" user-emacs-directory)` is a magic string. After the parameters.el split, this path changes. Question: should code-structure file paths (like "where does gptel.el live?") be in config files alongside operational paths? Or is that over-engineering a simple filepath?
**Note:** Could have `configs/iar_file_paths.el` and `configs/core_file_paths.el` but that seems like over-engineering. Make a decision during refactor. If paths stay hardcoded, at least use a defconst so they're visible at the top of the file.

### 3. Duplicate `defvar` declarations lack comment [DOC]
**Problem:** `iar-gptel-backend`, `iar-gptel-default-model`, `iar-fork-path` are defvar'd here AND in metaconfig/gptel.el (first two) and parameters.el (fork path). This is the forward-declaration pattern used across the codebase, but unlike other files, there's no comment explaining it.
**Fix:** Add a comment like other files have: "Declared in metaconfig/gptel.el (loaded inside :config below)" and "Declared in metaconfig/parameters.el (loaded before init.d modules)."

### 4. Fork path check ordering undocumented [DOC]
**Problem:** The fork path check happens before `use-package` intentionally -- if it happened inside `:config`, gptel would already be loaded from ELPA and the fork would be ignored. The ordering is correct but undocumented. Someone could "clean up" by moving it inside `:config` and silently break the fork override.
**Fix:** Add a comment explaining that the load-path manipulation MUST happen before `use-package` loads gptel.

## Patterns to Watch

- **Forward-declaration pattern:** `defvar` in consuming module, `defcustom`/`setq` in config module. Consistent across the codebase. Needs documenting in GUIDELINES.md with a standard comment format.
- **Code-structure paths vs. operational paths:** Distinguish between "where does this file live in the codebase?" (code structure, probably hardcoded or defconst) and "where does the audit directory live?" (operational, belongs in config). Decision deferred to refactor.