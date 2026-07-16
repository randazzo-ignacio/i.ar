# tools/filesystem/append_file.el -- Annotation

## What It Does

Appends text to the end of a file. Same buffer-aware/disk-aware split as write_file. Auto-prepends a newline if the file doesn't end with one. File guard checked (with append exception). Audit logged on success.

## What's Good

- **Same structural pattern as write_file.** Guard check, buffer-aware split, `condition-case`, audit log, explicit requires. Consistent.
- **Newline prepending handled in both paths.** Buffer path checks last char of buffer. Disk path reads last byte via offset. Both correct.
- **`save-restriction` + `widen` in buffer path.** Correct -- narrowed buffer needs widening before `point-max`.
- **Disk path reads only the last byte.** Efficient -- doesn't read the whole file to check the last char.
- **Append exception in file guard.** HISTORY.log and LOGS.md are append-allowed. `iar--guard-check-append` filters those. Correct.

## Issues Found

### 1. Newline check logic duplicated [DRY -- NOTE]
**Problem:** Buffer path and disk path each implement newline detection differently. Same intent, two implementations.
**Decision:** User is not worried about tool implementation duplication. Tools are leaf nodes -- they work, they ensure security, and they don't couple with other code. Acceptable as-is.

### 2. `condition-case` gap on guard check [FLAG -- ALREADY TRACKED]
**Problem:** Guard check outside `condition-case`. Same as write_file.
**Fix:** Already flagged for refactor discussion.

### 3. Audit log only on success [ARCHITECTURE -- ALREADY TRACKED]
**Fix:** Centralized in tool call layer. Already tracked.

### 4. Legacy prefixes (`my-gptel--audit-log-append`, `iar--mygptel--`) [NAMING -- ALREADY TRACKED]
**Fix:** Already tracked.

### 5. `add-to-list 'gptel-tools` + `require 'gptel` [ARCHITECTURE -- ALREADY TRACKED]
**Fix:** Already tracked -- tool call layer abstraction.

## Patterns to Watch

- **Tools are leaf nodes.** They don't couple with other code. Internal duplication in tools is acceptable as long as they work and ensure security. Different standard than shared modules. GUIDELINES.md candidate: tools follow a simpler standard -- correct, secure, self-contained. DRY is secondary.
- **Buffer-aware vs. disk-aware split is consistent across write tools.** write_file and append_file both follow the same pattern. Watch if replace_in_file does too.