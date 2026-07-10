# TODO

## Infrastructure
- [ ] Finish setting up homelab
  - [ ] Set up backups (NAS setup and borgbackups installed, systemd timer missing for auto backups)
  - [ ] Separate infrastructure

## i.ar Framework (from mccarthy)
- [ ] Phase 3: Token Budget Management for Ollama Cloud
  - Weekly counter for Ollama Cloud usage, persist across restarts
  - When budget exhausted, cloud-assigned agents fall back to tier 3 (3080)
  - Reset weekly
  - File: `init.d/token_budget.el`

- [ ] Phase 5: Local Inference Fallback for Sharing
  - Detect at startup: if no remote backends, define local Ollama backend
  - Small model (3B-8B) for weak hardware
  - `execute_code_remote` degrades to `execute_code_local` with note
  - Deprioritized -- build for author's hardware first

- [ ] Phase 6: Continuous Agents (NPU-Powered Autonomous Loops)
  - Timer-driven agents that wake, work, sleep autonomously
  - State carried between ticks via state files (not persistent process)
  - Overlap handling: skip new tick if previous still running
  - Notifications: D-Bus desktop notifications + *continuous-agents* buffer
  - Use cases: Gardener (codebase monitor), Watcher (infra monitor), Librarian (doc maintainer), Scribe (session secretary)
  - File: `init.d/continuous_agent.el`
  - Prerequisites: Local Ollama on laptop, small NPU-compatible model

## Security (from finch)
- [ ] Restrict outbound network access -- whitelist CTF challenge IPs/domains
- [ ] Implement iptables/network restrictions to enforce the whitelist
- [ ] Log all outbound connections for post-CTF review
- [ ] Block exfiltration paths -- prevent curl/wget to non-CTF addresses
- [ ] Add scope constraint directives to CTF agents
- [ ] Add no-destructive-action directive to CTF agents
- [ ] Add stealth directives to CTF agents
- [ ] Consider a "frozen" mode for CTFs where file modification tools are disabled
- [ ] Explore sandboxed execution -- separate reasoning context from execution context
- [ ] Evaluate per-agent network policies

## Auditor Testing (from auditor)
- [ ] Test auditor agent with a live delegation chain
  - Verify it delegates to reader for recon
  - Verify it routes to coder for payload crafting
  - Verify it uses reviewer for safety checks before execution
- [ ] Create a test target for non-destructive demos (DVWA or custom)
- [ ] Verify engagement rules are enforced through delegation

## CTF Wizard (from ctfwizard)
- [ ] Lock down self-modification for CTF sessions: `(setq my-gptel--guard-allow-self-modification nil)`
- [ ] Enable output sanitizer in ctfwizard session: `(setq-local my-gptel--sanitize-exec-output t)`
- [ ] Edit ctfwizard prompt.org to insert CTF rules and scope

## Knowledge Base Restructuring
- [ ] Rename nacho agent to mirror (generic agent, no PII in prompt.org)
  - Move Nacho's identity, working style, blind spots to knowledge/user/
  - Any agent can load knowledge/user/ to know who the user is
- [ ] Create knowledge/user/ knowledge base
  - User bio, working style, blind spots, projects, homelab context
  - Loadable by mirror, ctfwizard, auditor, or any agent via C-c k
- [ ] Separate knowledge base into its own git repo
  - Move knowledge/ out of i.ar/ repo into standalone repo
  - Update emacboros.sh --knowledge flag to point at new repo path
  - Users clone i.ar without getting author's personal knowledge
