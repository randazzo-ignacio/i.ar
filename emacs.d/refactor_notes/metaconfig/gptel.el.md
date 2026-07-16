# metaconfig/gptel.el -- Annotation

## What It Does

Configures the Ollama backend for gptel. Three things: determines which host to connect to, creates the backend with available models and request params, and picks the default model.

## What's Good

- **Env var overrides on everything that matters.** Host, context window, model. Agent loop can override per-run without editing config. Good design.
- **The model-must-be-in-list comment.** Explicitly documents that a typo will fail fast. Good.
- **Tiny and focused.** Does one thing, does it clearly. This is what parameters.el should aspire to be after the split.

## Issues Found

### 1. All configs should move to configs/gptel.el [STRUCTURAL -- MAJOR]
**Problem:** Hardcoded WireGuard IP (10.66.0.5:11434), hardcoded request params (temperature, top_p, num_predict), hardcoded models list. All of these are user-tunable values that belong in the future `emacs.d/configs/gptel.el` config file (part of the parameters.el split). This file should only read from configs and fall back to sane defaults.
**Fix:** Move all tunable values (host, models, request params, default model) to `configs/gptel.el`. This file becomes a thin bootstrap: read configs, create backend, set default model. Fallback to localhost:11434 if host unset.

### 2. Hardcoded WireGuard IP [PRIVACY -- resolved by issue 1]
**Problem:** `10.66.0.5:11434` is Nacho's specific network topology. Fork users have different Ollama hosts.
**Fix:** Fallback to `localhost:11434`. The env var override stays as the primary mechanism.

### 3. Request params hardcoded [CONFIG -- resolved by issue 1]
**Problem:** Temperature 0.7, top_p 0.90, num_predict 65536 are tuning knobs that require editing this file to change.
**Fix:** Move to `configs/gptel.el` as defcustoms.

### 4. Models list hardcoded [CONFIG -- resolved by issue 1]
**Problem:** Adding a model means editing this file.
**Fix:** Move to `configs/gptel.el` as a defcustom list.

### 5. No `provide` statement [BUG]
**Problem:** File is loaded via `load-file` from `iar-gptel-setup.el`, not via `require`. No provide needed currently, but should have one for consistency and future flexibility.
**Fix:** Add `(provide 'iar-gptel-config)` (or appropriate name after the split).

### 6. Dense `num_ctx` let-binding [DRY -- resolved by issue 1]
**Problem:** Env var read, string-to-number, validation, and fallback all inline in a backtick-quoted plist. A named function like `iar--env-int-or-default` would be cleaner and reusable. Same DRY pattern as the `:safe` lambdas in parameters.el.
**Fix:** Extract to helper function, or move the config to `configs/gptel.el` where it can be a clean defcustom with `:safe` predicate.

## Key Insight

Every issue in this file resolves to the same root cause: tunable values living in a bootstrap file instead of a config file. The split of parameters.el into `configs/*.el` files fixes all of them. This file becomes: read config, create backend, done.