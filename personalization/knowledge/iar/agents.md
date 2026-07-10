# i.ar Agent System

## Agent Categories

### Primary Agents (user-facing)

| Agent | Role | Status |
|-------|------|--------|
| **nacho** | Mirror agent for Ignacio. Challenges assumptions, pushes back on practicality, helps decide things. | Active, primary |
| **darwin** | Autonomous self-modifying agent. Runs in cycles, makes one small change, tests, logs, sleeps. | Active, autonomous |
| **auditor** | Security audit orchestrator. Delegates recon, analysis, action. Non-destructive. | Active, used for real audits |
| **ctfwizard** | CTF orchestrator. Delegates to specialists, coordinates attack chains. | Active, used for CTFs |

### Sub-Agents (delegated by orchestrators)

| Agent | Role | Parent Agents |
|-------|------|---------------|
| **reader** | READ-ONLY reconnaissance. Fetches external content, reports findings. | auditor, ctfwizard |
| **actor** | Action agent. Receives sanitized intel, decides actions, captures flags. | ctfwizard |
| **coder** | Python code writer. Clean, modular, optimized. | auditor, ctfwizard, darwin |
| **researcher** | Security researcher. CVE analysis, threat intelligence. | auditor, ctfwizard |
| **reviewer** | Strict code reviewer. Security-first, no flattery. | darwin (for code review) |

### Deprecated/Experimental Agents

| Agent | Status | Notes |
|-------|--------|-------|
| **mccarthy** | Deprecated | Lisp philosopher personality. Knowledge should move to `knowledge/iar/`. |
| **ouroboros** | Deprecated | Original self-modification agent. Replaced by darwin. |
| **sage** | Deprecated | Elisp expert. Knowledge already in `knowledge/iar/modules.md`. |
| **finch** | Deprecated | Harold Finch roleplay. Fun but underutilized. |
| **machine** | Deprecated | The Machine roleplay. Companion to finch. |
| **ignisp** | Experimental | ignisp programming language design agent. Separate project. |

## Personality vs Knowledge

The design principle: **agent prompt.org defines WHO the agent is, knowledge files define WHAT the agent knows.**

- `C-c a <name>` loads the agent personality (prompt.org + #+INCLUDE expansion)
- `C-c k <folder>` loads knowledge files on top of the personality
- `C-c p` shows total prompt size

This separation prevents agent duplication. Instead of having separate agents for "Elisp expert that knows i.ar" and "Reviewer that knows i.ar", you have one reviewer personality and load `knowledge/iar/` when needed.

## Agent Memory System

Each agent has three memory tiers:

1. **HISTORY.log** -- Operational log. Append-only. File-guard protected (cannot be overwritten). Format: `[YYYY-MM-DD HH:MM:SS] AgentName: concise description`. Used for audit trail.

2. **LOGS.md** -- Semantic session notes. What was discussed, decided, learned. Included in agent prompt via `#+INCLUDE`. Updated after significant sessions.

3. **SUMMARY.md** -- Compressed memory. The `C-c m` command (memory_tools.el) sends the conversation to the LLM for summarization, producing a compressed set of bullet points. Included in agent prompt via `#+INCLUDE`.

As LOGS.md and SUMMARY.md grow, they consume prompt tokens. Use `C-c p` to monitor total prompt size. If it gets too large, summarize and trim.

## Delegation Architecture

Orchestrator agents (auditor, ctfwizard) delegate to specialist agents (reader, actor, coder, researcher, reviewer) via the `delegate` tool.

Key properties:
- **Async**: Delegate runs in a separate buffer, Emacs stays responsive
- **Streaming**: Sub-agent output is mirrored into parent buffer in real-time
- **Depth-limited**: Max delegation depth (default 3) prevents infinite recursion
- **Turn-limited**: Max text-only turns (default 15) prevents models that narrate instead of acting from running forever
- **Timeout**: Default 600 seconds per delegation
- **Unknown tool blocking**: Hallucinated tool names are intercepted early

## Darwin Autonomous Mode

Darwin is special. It runs in a loop without human direction:

1. Read own source code
2. Identify one small improvement
3. Make the change
4. Run tests
5. Log what it did and why
6. Sleep
7. Repeat

Darwin's constraints:
- `init.el` is immutable (cannot modify the entry point)
- Cannot delete other agents
- Tests must pass (or the change is reverted)
- One change per cycle (small, deliberate mutations)
- Self-modification mode must be enabled for .el file changes

Darwin has its own elisp modules (`darwin_cycle.el`) and shell scripts (`darwin-cycle.sh`, `darwin-loop.sh`) for cycle management.