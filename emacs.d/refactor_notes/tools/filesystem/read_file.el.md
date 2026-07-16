# tools/filesystem/read_file.el -- Annotation

## What It Does

Reads file contents into a string. Truncates at `iar-fs-read-max-size` characters if exceeded, appending a truncation notice. Same tool registration pattern as list_directory.

## What's Good

- **Character count, not byte count.** Docstring explains: `insert-file-contents` decodes, token consumption correlates with characters. Correct reasoning.
- **`with-temp-buffer` + `insert-file-contents`.** Clean -- no buffer pollution, no buffer-aware logic needed.
- **Truncation with notice.** Agent knows the file was truncated and at what size.
- **Same `condition-case` error pattern as list_directory.** Consistent.
- **Runtime validation on `iar-fs-read-max-size`.** `integerp` + `> max 0`. Same defense-in-depth pattern.
- **Minimal dependencies.** Only `require 'gptel`. No `cl-lib` needed.

## Issues Found

### 1. No forward declaration for `iar-fs-read-max-size` [CONVENTION -- ALREADY TRACKED]
**Fix:** Already tracked -- forward-declaration convention.

### 2. Truncation notice is hardcoded [STRUCTURAL -- ALREADY TRACKED]
**Problem:** `"[... file truncated at %d characters ...]"` -- same pattern as tool-result-truncation notice. Question: is this prompt text (should be externalized) or a system/API message (stays in code)?
**Note:** Closer to the tool-result-truncation notice -- a system message to the agent, not a prompt template. Same category as tool descriptions? Needs decision during refactor. Already tracked.

### 3. `add-to-list 'gptel-tools` + `require 'gptel` [ARCHITECTURE -- ALREADY TRACKED]
**Fix:** Already tracked -- tool call layer abstraction.

### 4. `iar--mygptel--` prefix [NAMING -- ALREADY TRACKED]
**Fix:** Already tracked -- rename after tool call layer.

## Patterns to Watch

- **Read-only tools are simpler than write tools.** No file guard, no audit logging, no buffer-aware logic. The tool call layer will centralize audit logging, but read-only tools will still be simpler than write tools.
- **Truncation notices as system messages:** Different from prompt templates (which couple files) but same as tool descriptions (which are API contracts). Needs a GUIDELINES.md decision: are system messages (truncation notices, error messages) prompt text or code?