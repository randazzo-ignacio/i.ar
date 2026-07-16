# shared/iar-agent-utils.el -- Annotation

## What It Does

Validation and path resolution for agent names, task names, and per-agent directories. The security boundary for "which agent are you, and where can you read/write." Consumed by task tools, agent loader, delegate, reload, and memory tools.

## What's Good

- **Security is taken seriously.** String anchors (not line anchors) prevent multi-line bypass. `file-truename` traversal defense on every path resolution. Two layers of validation (name + path). Correct posture for the function that decides where agents can write.
- **`iar--valid-name-p` docstring explaining anchor choice.** Subtle security point most people get wrong. Documented inline.
- **`file-truename` check is the right approach.** Regex on string path is bypassable (symlinks, `..`). Resolving to real path and checking prefix is correct.
- **Consolidation is clean.** One `valid-name-p` replaces two functions.

## Issues Found

### 1. Backward-compat aliases should be removed [CLEANUP]
**Problem:** `iar--valid-agent-name-p`, `iar--valid-task-name-p`, `iar--get-agent-dir` are aliases kept for backward compatibility with older code and tests.
**Fix:** Remove all three aliases during refactor. Update all callers to use the canonical names: `iar--valid-name-p`, `iar--resolve-agent-tasks-dir`.

### 2. `iar--resolve-agent-dir` accepts arbitrary base strings [BUG -- OVERSIGHT]
**Problem:** The `if/else` chain maps "tasks" and "audit" to their defvars, but any other string (e.g., "knowledge") falls through and is used as a literal path. No error on unrecognized base.
**Fix:** Add an else clause that signals an error for unrecognized base values. Or restructure as a lookup table / cond.

### 3. "unknown" sentinel instead of nil [BUG -- KNOWN SYMPTOM]
**Problem:** `iar--get-agent-name` returns "unknown" as a fallback. `iar--resolve-agent-dir` checks `(equal agent-name "unknown")` -- a string comparison against a magic string. If `iar--get-agent-name` changes its fallback, this breaks silently. User reports FSM logs have been dumping into the "unknown" agent directory, suggesting the agent name resolution is failing in some contexts and the "unknown" sentinel is being used as a real agent name.
**Fix:** `iar--get-agent-name` should return nil instead of "unknown". Callers check for nil. This is a cleaner sentinel and prevents "unknown" from being used as a directory name. The FSM log issue needs closer investigation during refactor but may originate in another file (debug modules or agent-cycle setting the global/buffer-local vars).

### 4. `iar--validate-agent-name` and `iar--validate-task-name` are identical except error message [DRY]
**Problem:** Same validation logic (`iar--valid-name-p`), different error messages. 3 lines each.
**Fix:** Could be a macro or a single function with a context parameter. Minor -- 3 lines each is borderline. User leans toward macro.

### 5. Tasks model: files -> folders [STRUCTURAL -- REFACTOR]
**Problem:** Current model: one `.md` file per task. Proposed model: `tasks/<agent>/<task-name>/` directory with `description.md` and subtask files inside. This changes the path resolution logic in `iar--resolve-task-path` and all task tools (read_tasks, write_task, remove_task).
**Fix:** `iar--resolve-task-path` needs to resolve to a task directory, not a single file. Task tools need to handle directory listing (read_tasks), directory creation (write_task), and recursive deletion (remove_task). This is a data model change, not just a path change. Tracked as part of the refactor since the task model is being restructured.

### 6. Double traversal check in `iar--resolve-task-path` [NOTE -- DEFER]
**Problem:** `iar--resolve-agent-dir` already does `file-truename` check. `iar--resolve-task-path` does another one. Task name is already validated to `[a-zA-Z0-9_-]+` so traversal via the name is impossible. The second check is defense-in-depth against validated input.
**Decision:** Leave as-is for now. Revisit after full audit. Defense-in-depth is not wrong, just potentially redundant.

## Patterns to Watch

- **Backward-compat aliases:** All should be removed during refactor. Check every module for alias usage and update callers. This is a global pattern, not specific to this file.
- **Magic string sentinels:** "unknown" is a magic string used as a fallback. Nil is cleaner. Watch for other magic string sentinels in the codebase.
- **String-to-variable mapping in `resolve-agent-dir`:** The `if/else` chain mapping "tasks"/"audit" to defvars is fragile. A lookup table or explicit cond with error handling is better.