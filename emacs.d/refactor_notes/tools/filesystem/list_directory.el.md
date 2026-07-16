# tools/filesystem/list_directory.el -- Annotation

## What It Does

Lists directory contents. Returns newline-separated names, dotfiles included, directories suffixed with `/`, sorted alphabetically. One tool registration at the bottom.

## What's Good

- **`condition-case` with informative error.** Returns path + Emacs error. Good for debugging.
- **Directories suffixed with `/`.** Clean way to distinguish files from dirs in plain text.
- **`cl-remove-if` for `.` and `..`.** Explicit exclusion. Correct.
- **`string-lessp` sort.** Deterministic output.
- **`expand-file-name` on path.** Normalizes before use.
- **No size limit on output.** Tool result truncation handles this at the truncation layer. Correct separation of concerns.

## Issues Found

### 1. `add-to-list 'gptel-tools` at load time [ARCHITECTURE -- ALREADY TRACKED]
**Problem:** Registers with gptel's tool list directly. With tool call layer, registers with i.ar's tool list.
**Fix:** Already tracked -- tool call layer abstraction.

### 2. `require 'gptel` [ARCHITECTURE -- ALREADY TRACKED]
**Problem:** Direct dependency on gptel for `gptel-make-tool` and `gptel-tools`. With tool call layer, becomes `require` on i.ar's tool module.
**Fix:** Already tracked.

### 3. `iar--mygptel--` prefix [NAMING -- ALREADY TRACKED]
**Fix:** Already tracked -- rename after tool call layer.

### 4. No audit logging [ARCHITECTURE -- NOTE]
**Problem:** Read-only operation, not audited. Currently audit logging is per-tool (write, replace, append, exec). With the tool call layer, audit logging becomes centralized -- every tool call is logged in the abstraction, individual tools don't need to implement it.
**Fix:** Centralize audit logging in the tool call layer. Every tool inherits logging. No per-tool audit logging code.

## Patterns to Watch

- **Tool descriptions stay in English alongside the code.** Tool descriptions are API contracts with the LLM, not prompt templates. They stay in the code, in English. Most models are multilingual, and those that aren't include English from training data. GUIDELINES.md rule.
- **Tool registration pattern:** `add-to-list 'gptel-tools` + `gptel-make-tool` at the bottom of every tool file. Consistent across all tool modules. With the tool call layer, this becomes `iar--make-tool` or similar, but the pattern stays the same: define function, register tool, provide.
- **Read-only tools skip file guard and audit logging.** Correct for now, but the tool call layer centralizes both -- file guard checks happen in the abstraction (if applicable), audit logging happens in the abstraction (always).