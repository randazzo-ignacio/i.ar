# core/iar-evil-mode.el -- Annotation

## What It Does

Loads evil mode (vim keybindings) and evil-collection (vim bindings for built-in Emacs modes). 20 lines. Copy-pasted from a forum, works, not deeply understood.

## What's Good

- **It works.** Correct `defvar` + `setq` pattern for pre-load config of evil variables, even if the reason wasn't fully understood when written.
- **`evil-want-keybinding nil` is correct** for evil-collection usage.

## Issues Found

### 1. `declare-function` calls may be unnecessary [INVESTIGATE DURING REFACTOR]
**Problem:** `declare-function` for `evil-mode` and `evil-collection-init` are forward declarations for the byte-compiler. Since this file is loaded via `load` (not byte-compiled) and `use-package :ensure t` loads the packages at runtime, these may be unnecessary.
**Fix:** Investigate during refactor. If byte-compilation is never run on this file, remove them. If it is, keep them and understand why.

### 2. `evil-collection-init` with no args [INVESTIGATE DURING REFACTOR]
**Problem:** Initializes evil-collection for ALL built-in modes. In a minimal container Emacs, many modes don't exist. May produce warnings in `*Messages*`.
**Fix:** Check if evil-collection handles missing modes gracefully. If it warns, consider passing a list of specific modes to init.

### 3. Module may be temporary [NOTE]
**Problem:** User is using evil mode as a bridge while learning Emacs keybindings. Once graphical Emacs arrives, user will decide whether to keep evil or drop it entirely.
**Note:** Do not invest heavily in customizing this module. It may be deleted. Any changes during refactor should be minimal (cleanup only). If evil is dropped, this file and its init.el load line are removed.

## Patterns to Watch

- **Copy-paste modules:** This file was copied from a forum without deep understanding. During refactor, every line should be understood well enough to explain. If a line can't be explained, it either gets learned or removed. No cargo-cult code.
- **Temporary bridges:** Evil mode is a bridge, not a permanent decision. Watch for other bridge modules that might be removed once their replacement is ready.