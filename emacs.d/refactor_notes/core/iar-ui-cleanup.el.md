# core/iar-ui-cleanup.el -- Annotation

## What It Does

Disables menu bar, tool bar, and startup message. 11 lines.

## What's Good

- **`fboundp` guards.** Correct for minimal/batch Emacs where these functions don't exist. Defensive without being paranoid.
- **No scroll-bar-mode.** Not present in terminal Emacs. Correct omission.
- **No config, no defcustoms.** Environment fact, not a preference. Same pattern as locale.el.

## Issues Found

### 1. No display-type conditional [STRUCTURAL -- TIES TO GRAPHICAL EMACS TASK]
**Problem:** Currently always disables menu bar and tool bar. With graphical Emacs (tracked task: graphical-emacs-mcp-integration), a windowed environment may want these enabled. File needs a conditional check on display type.
**Fix:** Check `display-graphic-p` (or equivalent). In terminal: disable everything (current behavior). In GUI: keep menu-bar-mode and tool-bar-mode enabled, or make it configurable. This ties to the graphical Emacs task and should be done when that work happens.

### 2. Missing `inhibit-splash-screen` [BUG -- MINOR]
**Problem:** Only `inhibit-startup-message` is set. This suppresses the echo area message but not the splash buffer. In terminal mode both should be suppressed.
**Fix:** Add `(setq inhibit-splash-screen t)`.

## Patterns to Watch

- **Display-type conditionals:** When graphical Emacs arrives, multiple modules may need display-type checks. Consider a shared helper like `iar--gui-p` that returns non-nil in graphical mode. Centralizes the check so modules don't each call `display-graphic-p` independently.