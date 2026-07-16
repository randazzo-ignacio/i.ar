# security/iar-audit-log.el -- Annotation

## What It Does

Appends timestamped entries to a central audit log for every file operation and command execution. Best-effort -- never breaks the operation it's auditing. Includes log rotation and log injection prevention.

## What's Good

- **Log injection prevention.** Sanitizing newlines/CR in detail prevents fake audit entries via malicious filenames. Real attack vector, correctly handled.
- **Best-effort with `condition-case` everywhere.** Audit logging never breaks the operation being audited. Right principle, consistently enforced.
- **`write-region` with append and silent.** Direct append, no temp buffer, no messages. Efficient.
- **Command truncation in `-audit-log-exec`.** 200 chars with "..." -- prevents log bloat from long commands. Practical.
- **Sanitization invariant documentation.** "TOOL is a hardcoded string literal... AGENT comes from `iar--get-agent-name`... neither is user-controlled, so neither is sanitized. If this invariant changes, sanitize them too." Documents the trust boundary and what would need to change.
- **Rotation defense-in-depth.** `:safe` predicate at file-local level + runtime validation in function. Matches defense-in-depth pattern.
- **Log format hardcoded is fine.** Unlike prompt text (which couples files), the audit log format is self-contained. No other file needs to parse it (except log utils, which are a separate concern). Different from the prompt-text-in-elisp issue.

## Issues Found

### 1. `my-gptel--` prefix is legacy [NAMING -- CLEANUP]
**Problem:** Every function uses `my-gptel--` prefix but this module has nothing to do with gptel. It's an audit log. Leftover from before the naming refactor.
**Fix:** Rename to `iar--audit-` or similar. Update all callers. This is a naming convention issue for GUIDELINES.md.

### 2. Missing forward declarations [CONVENTION -- ALREADY TRACKED]
**Problem:** `iar-audit-log-max-size` is used but not forward-declared with `defvar`. `iar--audit-log-path` is available via `require 'iar-utils` but not explicitly declared.
**Fix:** Add `defvar` forward declarations for both, following the convention. Already tracked as a GUIDELINES.md rule.

### 3. Stale comment about workspace/ [DOC]
**Problem:** Comment says "audit log is not protected by iar-file-guard (it lives in workspace/ which is the designated writable area)." But the audit log lives at `audit/audit.log` under emacs.d, not workspace/. Comment is from when the log was in a different location.
**Fix:** Update comment to reflect actual path. Remove workspace reference.

### 4. Workspace directory architecture needs rethinking [ARCHITECTURE -- NOTE]
**Problem:** The "workspace" concept is currently wrong. There needs to be a dedicated workspace directory for agent-host file sharing that does NOT live in `.emacs.d/`. Currently agents share files through ad-hoc mounts and the audit directory.
**Note:** This is a larger architecture discussion, not a file-guard issue. Track for post-refactor planning. The workspace dir should be a first-class concept, not an afterthought.

### 5. Directory existence check doesn't belong here [CLEANUP]
**Problem:** `my-gptel--audit-log` checks if the log directory exists and creates it if not. This is not the job of the logging function -- it's the job of initialization (init.el or a setup function).
**Fix:** Move directory creation to init.el or a setup function. The log function should assume the directory exists. If it doesn't, the `condition-case` handles the error gracefully (best-effort logging).

## Patterns to Watch

- **`my-gptel--` legacy prefix:** Watch for this prefix across the entire codebase. All instances should be renamed during the refactor. Track how many modules still use it.
- **Best-effort pattern:** `condition-case` wrapping that catches all errors and continues. Used in audit logging, should be used wherever a secondary operation must never break the primary one. GUIDELINES.md candidate.
- **Log format vs. prompt text:** Log format strings are self-contained -- no cross-file coupling. Prompt text strings couple elisp to prompt files. Different concerns, different rules. Hardcoding log format is fine; hardcoding prompt text is not.