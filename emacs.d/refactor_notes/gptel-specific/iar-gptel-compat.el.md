# gptel-specific/iar-gptel-compat.el -- Annotation

## What It Does

Wraps all gptel internal symbols that i.ar hooks into. Provides a single indirection point -- if gptel's internals change, only this file needs updating. Three categories: direct function wrappers, hook variable aliases (defvaralias), and centralized advice installation helpers.

## What's Good

- **The header comment is excellent.** Lists every category wrapped, explains what's NOT wrapped (public API), states the purpose. Architectural contract documented.
- **defvaralias for hooks is the right call.** `add-hook`/`remove-hook` work transparently through the alias.
- **The request-alist accessor is honest.** Comment explains why defvaralias doesn't work (buffer-local) and provides a read-only accessor.
- **`require 'gptel` at the top.** Explicit dependency. Won't load without gptel.

## Issues Found

### 1. This file should not exist [ARCHITECTURE -- MAJOR]
**Problem:** The entire compat layer is a hack. The real problem is that i.ar depends on gptel's internal FSM, curl internals, and tool processing internals at all. This was a quick hack to make features work and test the framework. Wrapping the internals provides indirection but doesn't solve the fundamental architectural problem: we shouldn't be looking into gptel's internals.

**Impact:** Every module that uses these wrappers needs rearchitecting:
- Debug modules (FSM tracer, request logger, buffer monitor) -- all use `:before` advice on gptel internals
- Tool result truncation -- uses `:around` advice on `gptel--process-tool-call`
- Loop guard -- uses `gptel-pre-tool-call-functions` hook (this one is a public hook, may be fine)
- Agent cycle -- uses FSM state monitoring, `gptel-post-response-functions` hook
- Tool guard -- uses `gptel-pre-tool-call-functions` hook

**Fix:** Remove this file. Have a long discussion about how to reimplement every feature that depends on gptel internals. Some hooks (pre/post-tool-call, post-response) may be public API and safe to keep. FSM access, curl internals, and tool processing are internal and need alternative approaches. This is the biggest architectural decision in the refactor.

### 2. File lives outside init.d/ [STRUCTURAL -- ALREADY TRACKED]
**Problem:** `gptel-specific/` lives at `user-emacs-directory/gptel-specific/` instead of inside `init.d/`.
**Note:** Moot if the file is removed. If it survives in some form, it moves inside `init.d/`.

### 3. `boundp` guards on defvaralias are redundant [CLEANUP -- MOOT]
**Problem:** `(when (boundp 'gptel-pre-tool-call-functions) ...)` -- `require 'gptel` guarantees these are bound.
**Note:** Moot if the file is removed.

### 4. `iar-gptel-fsm-last` hides a variable access as a function [INCONSISTENCY -- MOOT]
**Problem:** Other FSM wrappers call functions. This one reads a buffer-local variable. The wrapper hides the implementation detail. Inconsistent with the other wrappers.
**Note:** Moot if the file is removed.

## Key Insight

This file is the canary. It exists because i.ar reached into gptel's internals to build features quickly. The compat layer was the responsible way to do that (indirection, not direct coupling), but the real answer is: don't reach into gptel's internals at all. The refactor needs to answer: what does i.ar actually need from gptel, and can it get that through public API or its own implementation?

## Dependencies for the Discussion

Modules that use gptel internals (need rearchitecting):
- `debug/iar-fsm-tracer.el` -- advises `gptel--fsm-transition`, `gptel--process-tool-call`, `gptel--handle-tool-use`
- `debug/iar-request-logger.el` -- advises `gptel-curl--get-config`, `gptel-curl--stream-cleanup`, `gptel-curl--sentinel`
- `debug/iar-buffer-monitor.el` -- advises `gptel-send` (may be public API)
- `core/iar-tool-result-truncation.el` -- advises `gptel--process-tool-call`
- `security/iar-loop-guard.el` -- uses `gptel-pre-tool-call-functions` (may be public API)
- `security/iar-tool-guard.el` -- uses `gptel-pre-tool-call-functions` (may be public API)
- `agent/iar-agent-cycle.el` -- uses FSM state monitoring, `gptel-post-response-functions`

Hooks that may be public API (safe to keep):
- `gptel-pre-tool-call-functions`
- `gptel-post-tool-call-functions`
- `gptel-post-response-functions`

Internals that need alternative approaches:
- FSM access (`gptel-fsm-p`, `gptel-fsm-info`, `gptel-fsm-state`, `gptel--fsm-transition`, `gptel--fsm-next`, `gptel--fsm-last`)
- Tool processing (`gptel--process-tool-call`, `gptel--handle-tool-use`)
- Curl internals (`gptel-curl--get-config`, `gptel-curl--stream-cleanup`, `gptel-curl--sentinel`)
- Request tracking (`gptel--request-alist`)