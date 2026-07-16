# tools/filesystem/replace_in_file.el -- Annotation

## What It Does

Finds an exact text match in a file and replaces it. Same buffer-aware/disk-aware split as write and append. Guard checked, audit logged on success, atomic write for non-buffer path.

## What's Good

- **Same structural pattern as write_file and append_file.** Consistent across all three write tools.
- **"Target string not found" returns an error, not a silent no-op.** Critical -- silent no-op would make the agent think it succeeded.
- **`replace-match` with `t t` (literal + string).** No regexp interpretation of replacement. Correct for surgical replacement.
- **Atomic write for disk path.** Prevents stale buffer overwrites.

## Issues Found

### 1. Tool is rarely used and produces wrong output [ARCHITECTURE -- TASK CREATED]
**Problem:** LLM rarely uses replace_in_file correctly. When it does, it sometimes produces wrong output, and the LLM falls back to write_file. The tool tries to be sed in ~50 lines of elisp -- scope is huge for what it does.
**Fix:** Task created (`tool-inventory-review`) to decide which tools are actually necessary. This tool may be removed in favor of write_file covering the use case.

### 2. Only replaces first match [NOTE -- MOOT IF TOOL IS REMOVED]
**Problem:** `search-forward` finds first occurrence only. Multiple identical blocks = only first replaced. Not documented.
**Note:** Moot if tool is removed. If kept, document the behavior.

### 3. `make-temp-file "gptel-replace-"` prefix [NAMING -- ALREADY TRACKED]
**Fix:** Already tracked.

### 4. `condition-case` gap on guard check [FLAG -- ALREADY TRACKED]
**Fix:** Already flagged for refactor discussion.

### 5. Audit log only on success [ARCHITECTURE -- ALREADY TRACKED]
**Fix:** Centralized in tool call layer. Already tracked.

### 6. Legacy prefixes [NAMING -- ALREADY TRACKED]
**Fix:** Already tracked.

## Patterns to Watch

- **Tool scope vs. tool value.** replace_in_file tries to do something complex (text search + replace) in a small amount of code. The result is unreliable. Compare with write_file (simple: write content to path) and append_file (simple: add content to end). Simple tools work; complex tools need more support or should be removed. GUIDELINES.md candidate: tools should be simple and reliable. If a tool's scope exceeds its implementation, either expand the implementation or remove the tool.
- **Tool arg naming: hyphens vs. underscores.** Tool schema uses underscores (JSON), elisp uses hyphens (lisp). gptel handles the mapping. Note for GUIDELINES.md: document the convention.