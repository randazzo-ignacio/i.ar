# core/iar-package-setup.el -- Annotation

## What It Does

Bootstraps the package manager. Adds MELPA to archives, initializes packages, refreshes contents if empty. 9 lines.

## What's Good

- **Minimal and correct.** Does exactly what package setup requires and nothing else. No `use-package` here (that's in individual modules).
- **The `unless package-archive-contents` guard.** Avoids refreshing on every startup when contents already exist.
- **`t` as third arg to `add-to-list`.** Appends MELPA after GNU archive. Correct priority for core packages.

## Issues Found

### 1. `package-enable-at-startup` interaction [INVESTIGATE DURING REFACTOR]
**Problem:** Emacs 27+ has `package-enable-at-startup` which runs package initialization during startup. By calling `package-initialize` explicitly here, may be double-initializing. In practice it works, but the interaction is not documented.
**Fix:** Investigate `package-enable-at-startup` during refactor. Be explicit about it -- either disable it and keep the explicit call, or rely on it and remove the explicit call. Add a comment explaining the choice either way.

## Patterns to Watch

- **Environment facts vs. user preferences:** Same as locale.el. MELPA URL is an environment fact, not a preference. Correct to hardcode.
- **Network dependency in container:** `package-refresh-contents` requires network. Container has WireGuard-only networking. Works because packages are pre-installed in the image and the `unless` guard skips refresh when contents exist. Worth a comment if this is intentional.