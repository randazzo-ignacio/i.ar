# metaconfig/parameters.el -- Annotation

## What It Does

Single source of truth for all tunable parameters in the system. Every module that needs a configurable value declares a `defvar` forward declaration (just the name) and this file owns the `defcustom` (default value, type, customize integration). 39 defcustoms across 15 sections.

## What's Good

- **Everything is defcustom.** Users can tune via `M-x customize-group` without editing code. Right call for a config file.
- **Docstrings are thorough.** Every defcustom explains what it does, what the default means, and often why (buffer-hard-cap references the 2026-07-12 laptop crash). Excellent.
- **Header comment is excellent.** Explains the file's purpose, the defvar/defcustom pattern, and explicitly lists what's NOT here and why (telegram secrets, self-modification toggle).
- **`:safe` predicates on integer parameters.** Prevents file-local variable attacks (e.g., setting `iar-loop-soft-threshold` to -1 via file-local variables).

## Issues Found

### 1. Monolithic file -- should be split per-functionality [STRUCTURAL -- MAJOR]
**Problem:** 485 lines, 39 defcustoms, already too large to read in a single tool call. Will grow unbounded as features are added. Users can't find what they need without scanning the whole file. Analogous to sshd_config -- no single user knows every param without the manual.
**Fix:** Split into per-functionality config files. Each module (or module group) owns its own parameters file. Example structure:
```
metaconfig/
  paths.el          -- base directory paths
  keybindings.el    -- keybinding defcustoms
  delimiters.el     -- delimiters and markers
  git.el            -- git commit params
  delegate.el       -- delegation params
  cycle.el          -- agent cycle params
  loop-guard.el     -- loop guard params
  memory.el         -- memory tool params
  file-guard.el     -- file guard protected paths
  ... etc
```
init.el loads each one. Each file is small, focused, and discoverable.

### 2. Delegation result marker coupling [ARCHITECTURE]
**Problem:** `iar-delegation-result-marker` is a defcustom in parameters.el, but changing it requires manually updating the prompt template at `agents.d/common/delegated_task.org`. Config changes should not require prompt changes.
**Fix:** Move separator markers to `prompts/common/separators/*.org` files. Parameters.el reads them from file (single source of truth). Prompts `#+INCLUDE` the separator files. Changing the marker updates both config and prompts automatically.

### 3. Personal data in public repo [SECURITY/PRIVACY]
**Problem:** `iar-git-author-name` = "Ignacio Randazzo", `iar-git-author-email` = "ignacio@randazzo.ar" hardcoded in a public repo file. Fork users get Nacho's name on their commits.
**Fix:** Make these env vars, same pattern as `iar-fork-path` (which reads `EMACBOROS_GPTEL_FORK_PATH`). e.g., `IAR_GIT_AUTHOR_NAME`, `IAR_GIT_AUTHOR_EMAIL`. Fall back to "i.ar Agent" / `<agent>@i.ar.local` if unset.

### 4. `:group 'iar-cycle` is wrong [BUG]
**Problem:** Cycle parameters use `:group 'iar-cycle` but no `defgroup` for `iar-cycle` is declared. Creates an orphan group in Customize. All other defcustoms use `:group 'iar`.
**Fix:** Change to `:group 'iar`. Or declare `defgroup iar-cycle` as a subgroup of `iar` if separation is desired.

### 5. Repeated `:safe` lambda [DRY]
**Problem:** The exact same lambda `(lambda (v) (or (and (integerp v) (> v 0)) (null v)))` appears 6+ times. Also `(lambda (v) (and (integerp v) (> v 0)))` appears multiple times.
**Fix:** Extract to named predicates: `iar--positive-integer-or-nil-p`, `iar--positive-integer-p`. Define once, reference everywhere.

### 6. Redundant `or` in getenv [MINOR]
**Problem:** `(or (getenv "EMACBOROS_GPTEL_FORK_PATH") nil)` -- `getenv` already returns nil when unset. The `or` with `nil` is a no-op.
**Fix:** Just `(getenv "EMACBOROS_GPTEL_FORK_PATH")`.

### 7. File guard regexes too broad [SECURITY]
**Problem:** Regexes like `/HISTORY\\.log\\'` and `/LOGS\\.md\\'` match ANY file with that name, anywhere in the path. `/containers/` has no end anchor -- matches any path containing `/containers/` anywhere.
**Fix (two-part):**
- a) Prepend IAR_ to i.ar-specific files (e.g., `IAR_HISTORY.log`, `IAR_LOGS.md`) to reduce accidental collision with unrelated files.
- b) Replace regex-based protection with a manifest file listing exact paths/files to guard. The regex was the quick solution; the proper solution is an explicit manifest of what needs guarding. This also applies to the conditional-protected list (init.el, init.d/**/*.el, Containerfile, etc.).

### 8. `:safe` on string defcustoms [NOTE]
**Problem:** Only integer/choice types get `:safe` predicates. Strings and keys don't.
**Note:** For strings, `:safe` could check non-empty. For directory defcustoms, could validate the directory exists. Might be overkill -- write down as a consideration for GUIDELINES.md, not a mandatory pattern.

## Patterns to Watch

- **defvar forward declarations in modules:** Modules declare `(defvar iar-some-param)` then reference it. parameters.el owns the defcustom. This pattern works but means every new parameter requires two files to be edited. With the split, each module could own its own parameters file and the forward declaration would be in the same file -- but then init.el load order matters even more.
- **Section ordering becomes file ordering:** Once split, the order init.el loads the parameter files matters (e.g., paths must load before anything that uses paths). Same constraint, just visible at the file level instead of the section level.