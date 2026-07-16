# core/iar-mount-awareness.el -- Annotation

## What It Does

Parses the `IAR_EXTRA_MOUNTS` env var at load time, stores the result, and provides a function that formats the mounts as a system prompt section. This is how agents discover mounted directories without being told in conversation.

## What's Good

- **The env var format is simple and documented.** `path:ro,path:rw` -- no JSON, no complex parsing. Good for a shell script to produce.
- **Empty string when no mounts.** Agent loader can blindly append the result without checking. Clean API.
- **`with-temp-buffer` for string construction.** Idiomatic Emacs.
- **Default mode is "rw".** Sensible default for the person writing the shell flag.
- **`defvar` computed at load time is fine here.** `IAR_EXTRA_MOUNTS` is an env var set before Emacs starts. Genuinely can't change at runtime. No latent bug.

## Issues Found

### 1. No path validation [BUG]
**Problem:** `iar--parse-extra-mounts` checks that path is non-empty but doesn't check that it exists (`file-directory-p`). A typo in the env var produces a mount entry pointing to nothing. Agent tries `list_directory` and gets an error at use time.
**Fix:** Add `file-directory-p` check during parsing. Emacs is in the container with the mounts already active -- it can verify paths exist. Warn or skip invalid paths.

### 2. No mode validation [BUG -- MINOR]
**Problem:** Mode is whatever string is after the colon. `path:banana` shows up as "read-write" because `string= mode "ro"` is nil and it falls to the else branch. Silent misconfiguration.
**Fix:** Validate mode against `("ro" "rw")`. Error or warn on invalid mode. Default to "rw" only when mode is absent, not when it's invalid.

### 3. Hardcoded prompt string [STRUCTURAL]
**Problem:** "The following directories are mounted..." is hardcoded in elisp. Should follow the same pattern as delimiters/markers -- live in external files (e.g., `prompts/common/separators/`) and be read from file, not inline in code.
**Fix:** Move prompt templates to prompt files. Code reads them, same as the delegation-result-marker pattern noted in parameters.el annotation. This is a GUIDELINES.md rule: **prompt text does not belong in elisp code.**

### 4. No `require` from agent-loader [STRUCTURAL]
**Problem:** agent-loader calls `iar--extra-mounts-prompt-string` but doesn't `require 'iar-mount-awareness`. The dependency is implicit -- init.el controls load order, so it works, but reordering init.el silently breaks it.
**Fix:** Add `(require 'iar-mount-awareness)` in agent-loader. This is a GUIDELINES.md rule: **modules with explicit dependencies must `require` those dependencies. Load order in init.el is for init.el to manage, but modules should fail loudly if their dependencies aren't loaded, not silently produce empty results.**

## Patterns to Watch

- **Prompt text in elisp:** This is the second occurrence (first was delegation-result-marker coupling in parameters.el). Pattern forming: all prompt text, delimiters, and markers should live in prompt files, not in elisp code. Strong GUIDELINES.md candidate.
- **Implicit dependencies via load order:** Modules relying on init.el load order without `require` are fragile. The `require` pattern makes dependencies explicit and produces errors when violated. Strong GUIDELINES.md candidate.
- **`push` + `nreverse` list construction:** Classic Lisp idiom. Correct and efficient. No issue.