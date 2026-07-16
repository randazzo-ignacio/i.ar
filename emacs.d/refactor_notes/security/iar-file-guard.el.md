# security/iar-file-guard.el -- Annotation

## What It Does

Enforces protected path rules against write, replace, and append operations. Two tiers: always-protected (agent prompts, base context, HISTORY.log, LOGS.md) and conditionally-protected (.el files, Containerfile, emacboros.sh, containers/, git hooks). Self-modification mode relaxes tier 2 but never tier 1. Includes symlink defense.

## What's Good

- **The `:safe` omission on `iar-guard-allow-self-modification` is deliberate and documented.** File-local variables can't silently enable self-modification -- Emacs prompts the user. Excellent security-conscious design.
- **Symlink defense.** Both expanded path and truename are checked. Symlink bypass attempts are caught.
- **`condition-case` on `file-truename`.** Falls back to expanded path if file doesn't exist. Defensive without being paranoid.
- **Two-tier model is the right abstraction.** Always-protected vs. conditionally-protected maps to the trust model. Self-modification is a flag, not a pattern.
- **Append exception is per-pattern, not per-tier.** HISTORY.log is always-protected but append-allowed. "You can always append to history, but never overwrite it." Correct semantics.
- **Return value is the reason string.** Callers can display the reason to the agent. Better than t/nil -- the agent knows WHY it was blocked.
- **Security-efficiency-cleanliness tradeoff triangle.** User is fine trading efficiency for clean, concise code that ensures security. This is a GUIDELINES.md principle.

## Issues Found

### 1. Patterns recompiled on every call [PERFORMANCE -- POST-REFACTOR NOTE]
**Problem:** `iar--guard--active-patterns` calls `iar--guard--compile-patterns` every time, creating new lambda closures. Every write/replace/append creates N closures (N = active patterns). Emacs has cooperative concurrency (single core), so this is real overhead on frequent operations.
**Decision:** Note for post-refactor optimization. May address on Day 3 if the list of similar notes is small enough. Cache compiled patterns, invalidate on config change.
**Tradeoff:** User is fine trading efficiency for clean code here. Security is the priority. If caching makes the code significantly more complex, skip it.

### 2. Regex patterns to be replaced with manifest [STRUCTURAL -- ALREADY TRACKED]
**Problem:** Regex patterns are too broad and missing anchors (tracked in parameters.el annotation). The guard logic is correct; the patterns it receives are the problem.
**Fix:** Replace regex-based protection with a manifest file listing exact paths/files to guard. The guard logic stays mostly the same -- just consumes a list instead of regex patterns. The manifest must be tiered (always-protected vs. conditionally-protected).

### 3. `iar--guard-check-replace` is a trivial delegate [NOTE]
**Problem:** Just calls `iar--guard-check-write`. Separate function exists for API symmetry.
**Note:** Keep for API symmetry. If replace ever needs different rules, the function is already there. Minor.

### 4. No guard-level logging of blocks [NOTE -- DEFER]
**Problem:** Guard returns reason to caller but doesn't log blocks independently. Audit logging happens at tool level.
**Decision:** User sees no value in separate block logging. The real value would be detecting a guard BYPASS (guarded file gets written) -- and that's a different problem (integrity checking, not logging). Defer further discussion to Day 3.

## Patterns to Watch

- **Security-efficiency-cleanliness tradeoff triangle:** User explicitly endorses trading efficiency for clean, concise, secure code. This is a GUIDELINES.md principle: when security and efficiency conflict, security wins. When cleanliness and efficiency conflict, cleanliness wins (unless the efficiency issue is measured and significant).
- **`:safe` omission as security measure:** Intentionally omitting `:safe` on security-sensitive defcustoms so Emacs prompts on file-local variable changes. Watch for other security-sensitive defcustoms that should follow this pattern.
- **Return reason strings, not booleans:** Guard functions return the reason for blocking, not just t/nil. Callers can display the reason. Better API for security checks.