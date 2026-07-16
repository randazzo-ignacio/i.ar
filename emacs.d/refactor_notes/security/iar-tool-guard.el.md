# security/iar-tool-guard.el -- Annotation

## What It Does

Blocks hallucinated tool names before they reach gptel's tool handling. A pre-tool-call hook that checks if the tool name exists in `gptel-tools`. If not, returns `(:block message)` with a clean error from a prompt template. Used by delegate buffers and cycle buffers.

## What's Good

- **The docstring is a technical deep-dive.** Explains TPRE stage interception, why it's better than gptel's built-in handling, how `gptel-tools` is resolved via buffer-local, and why `info :tools` isn't used. Prevents wrong "fixes."
- **Uses prompt template.** `unknown_tool.org` -- error message externalized. Consistent with loop-guard.
- **`gptel-tool-name` accessor.** Uses gptel's public accessor, not internal struct access.
- **Tiny and focused.** One function, one hook. No state, no config, no complexity.

## Issues Found

### 1. `require 'iar-gptel-compat` is unnecessary [CLEANUP]
**Problem:** Module requires the compat layer but doesn't use any compat layer functions. Uses `gptel-tools` (public) and `gptel-tool-name` (public) directly.
**Fix:** Remove the require. (If callers need the compat alias for the hook, they handle that themselves.)

### 2. Not loaded in init.el [BUG -- ALREADY TRACKED]
**Problem:** Loaded by `iar-delegate-tool.el` instead of init.el. Should be in the security section of init.el.
**Fix:** Already tracked in init.el annotation.

### 3. Reads `gptel-tools` directly [ARCHITECTURE -- ALREADY TRACKED]
**Problem:** Reads gptel's public variable. With the tool call layer abstraction, this reads i.ar's own tool list.
**Fix:** Already tracked -- tool call layer abstraction. This module becomes simpler with the abstraction.

### 4. `iar--mygptel--` prefix [NAMING -- ALREADY TRACKED]
**Problem:** Prefix indicates "hooks into gptel internals." With tool call layer, becomes `iar--block-unknown-tools`.
**Fix:** Already tracked -- rename after tool call layer is built.

### 5. No `require 'iar-prompt-loader` [CONVENTION -- ALREADY TRACKED]
**Problem:** `iar--load-prompt` declared but not required.
**Fix:** Already tracked as GUIDELINES.md rule.

## Patterns to Watch

- **Simplest example of gptel coupling.** This 51-line file reads `gptel-tools` and hooks into `gptel-pre-tool-call-functions`. With the tool call layer, both become i.ar-owned. The module becomes simpler, not more complex. This is the cleanest illustration of why the abstraction matters.
- **All issues already tracked.** This file has no new issues -- everything was surfaced by earlier files. Good sign that the pattern recognition is working.