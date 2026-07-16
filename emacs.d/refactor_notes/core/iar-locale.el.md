# core/iar-locale.el -- Annotation

## What It Does

Enforces UTF-8 everywhere. Five calls, no logic, no config. Terminal, keyboard, selection coding systems set to utf-8, prefer-coding-system to utf-8, language environment to UTF-8.

## What's Good

- **Header comment explains WHY, not just WHAT.** The `char-displayable-p` insight (returns nil for non-ASCII when `terminal-coding-system` is nil) is the kind of debugging knowledge that takes hours to derive and seconds to document. Exactly why inline comments matter.
- **Loads first.** Everything depends on UTF-8 working. Correct load order.
- **No defcustoms, no config, no parameters.** This is a fact about the environment, not a preference. Right call.
- **19 lines.** Does exactly what it needs to and nothing more.

## Issues Found

### 1. Typo in comment [DOC]
**Problem:** "iar-locale may not be set via environment variables" -- should be "locale may not be set." Copy-paste artifact from module name.
**Fix:** Replace "iar-locale" with "locale" in the comment.

## Patterns to Watch

- **Environment facts vs. user preferences:** This file is an environment fact (UTF-8 is required, not optional). The distinction between facts and preferences is a GUIDELINES.md candidate: facts go in code with no config, preferences go in config files with defcustoms.