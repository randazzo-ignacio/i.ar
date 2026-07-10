# TODO -- Infrastructure & Multi-Tier Architecture

## Overview

Four-tier infrastructure for the agent framework, each tier with a distinct role. Built for the author's hardware first, abstracted for sharing later.

## Tier Definitions

| Tier | Host | Hardware | Role |
|------|------|----------|------|
| 1 | Local (Emacs host) | Variable, weakest | Orchestrator. Runs Emacs, agent framework, tool layer. No inference. Future sharing target: laptop-only users point at remote Ollama. |
| 2 | 0b.ar | 64GB RAM, 16 CPU cores | Execution sandbox. SSH-accessible remote code execution. Docker, compilers, test suites. Root on a real VPS, isolated from daily driver. |
| 3 | 192.168.2.69 | 96GB RAM, 12 cores, RTX 3080 10GB VRAM | Primary inference. Ollama with mid-to-large models. Workhorse for most agents. |
| 4 | Ollama Cloud | 500B+ models, high speed | Frontier inference, budgeted. Flat rate, weekly token limit. Deep reasoning agents only. Falls back to tier 3 when budget exhausted. |

## Phase 1: Remote Execution Tool (`execute_code_remote`)

### Goal
New gptel tool that SSHes to 0b.ar and runs shell commands remotely. Keeps `execute_code_local` for filesystem operations in the Emacs container. Remote tool handles compute: Docker, compilation, test suites, long-running processes.

### Design
- Tool function: `my-gptel-tool-execute-remote (command &optional timeout)`
- SSH to `root@0b.ar` (configurable via `defcustom`)
- Execute command, stream output back to agent
- Timeout support (default 120s, configurable)
- Output truncation if exceeds max size (configurable, default 64KB)
- Configurable SSH user, host, port, key path via `defcustom`
- Optional command whitelist (disabled by default = full root)
- Graceful degradation: if SSH connection fails, return error message to agent (do NOT fall back to local execution silently -- agent should know the remote is down)

### Prerequisites
- [ ] Generate SSH keypair in Emacs container: `ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""`
- [ ] Authorize public key on 0b.ar: add `~/.ssh/id_ed25519.pub` to `root@0b.ar:~/.ssh/authorized_keys`
- [ ] Verify: `ssh -o ConnectTimeout=5 root@0b.ar "echo ok"`
- [ ] Install Docker on 0b.ar (if not already)
- [ ] Consider: dedicated user with limited sudo instead of root (future hardening)

### File
- `/root/.emacs.d/init.d/remote_exec_tool.el`
- Load from `init.el`

### Tool registration
```
gptel-make-tool
  :name "execute_code_remote"
  :description "Execute bash/shell commands on a remote VPS (0b.ar) via SSH. The remote server has Docker, compilers, and full compute resources. Use for compute-heavy tasks, test suites, container orchestration, and anything that should not run in the local Emacs container."
  :args [
    :name "command" :type "string" :description "The bash command to execute on the remote server."
    :name "timeout" :type "integer" :description "Maximum seconds to wait. Default 120." :optional
  ]
```

### Security considerations
- Agent has root SSH access to a VPS. It can do anything.
- Mitigations (future): SSH key with forced command, dedicated user, command whitelist, rate limiting.
- Current stance: full root on test server. Acceptable risk for the author's use case.
- For sharing: tool detects whether remote is configured. If not, degrades to `execute_code_local` with a note that remote execution is unavailable.

---

## Phase 2: Multi-Backend Configuration & Routing Table

### Goal
Rewrite `gptel_setup.el` to define multiple Ollama backends. Add a routing table mapping agent names to `(backend . model)` pairs. Delegate tool reads this table and sets `gptel-backend` and `gptel-model` buffer-locally per delegate.

### Design

#### Backends
- **Ollama-3080**: `192.168.2.69:11434` (existing, tier 3)
  - Models: granite4.1:8b-q8_0, gpt-oss:20b, gpt-oss:120b, mistral-medium-3.5:128b, nemotron-3-super:120b
  - Params: temperature 0.7, top_p 0.95, num_ctx 1048576, num_predict 65536

- **Ollama-Cloud**: Ollama's cloud endpoint (tier 4)
  - Models: nemotron-3-ultra:cloud, glm-5.2:cloud, (500B+ models TBD)
  - Params: same as above
  - Needs: API key / endpoint URL from Ollama cloud
  - [ ] Get Ollama Cloud API details (endpoint URL, auth method)

#### Routing table
```elisp
(defvar my-gptel-agent-routing
  '(("mccarthy"    . (:backend ollama-cloud  :model "glm-5.2:cloud"))
    ("coder"      . (:backend ollama-3080   :model "granite4.1:8b-q8_0"))
    ("reviewer"   . (:backend ollama-3080   :model "gpt-oss:20b"))
    ("researcher" . (:backend ollama-cloud  :model "glm-5.2:cloud"))
    ("finch"      . (:backend ollama-3080   :model "mistral-medium-3.5:128b"))
    ("machine"    . (:backend ollama-3080   :model "granite4.1:8b-q8_0"))
    ("ouroboros"  . (:backend ollama-3080   :model "nemotron-3-super:120b"))
    ("default"    . (:backend ollama-3080   :model "glm-5.2:cloud")))
  "Alist mapping agent names to backend/model pairs.")
```

#### Delegate tool changes
- In `my-gptel--spawn-delegate`, after setting `gptel-system-prompt`, look up agent name in routing table.
- Set `gptel-backend` and `gptel-model` buffer-locally based on routing entry.
- Fall back to `default` entry if agent not in table.
- Fall back to current global backend if no `default` entry.

### Files
- `/root/.emacs.d/init.d/gptel_setup.el` -- rewrite with both backends
- `/root/.emacs.d/init.d/delegate_tool.el` -- add routing lookup in spawn function

---

## Phase 3: Token Budget Management for Ollama Cloud

### Goal
Simple weekly counter for Ollama Cloud usage. When budget exhausted, cloud-assigned agents automatically fall back to tier 3 (3080 server). Reset weekly. Persist across Emacs restarts.

### Design
- `defcustom my-gptel-cloud-weekly-budget` -- token limit (default: estimate from Ollama Cloud plan)
- `defvar my-gptel-cloud-tokens-used` -- current week's usage
- State stored in `/root/.emacs.d/.cloud_budget` as a plist: `(:week-start "2026-06-23" :tokens-used 0)`
- On each cloud request: increment counter, check against budget, write state file
- If over budget: routing table returns tier 3 backend instead of cloud
- Weekly reset: compare current date to `:week-start`; if >7 days, reset counter
- [ ] Determine actual weekly token budget from Ollama Cloud plan
- [ ] Decide: count by tokens (need to parse response headers) or by requests (simpler, less accurate)

### File
- `/root/.emacs.d/init.d/token_budget.el`
- Load from `init.el`
- Integrate with routing table lookup in delegate tool

---

## Phase 4: Async Parallel Delegation

### Goal
Modify delegate tool to support fire-and-collect pattern. Spawn multiple agents simultaneously across different backends, then collect all results.

### Design

#### New tool: `delegate-async`
- `my-gptel-tool-delegate-async (agent task &optional context timeout)`
- Same as `delegate` but returns a task ID immediately instead of blocking
- Stores delegate-info in a global alist `my-gptel--async-tasks`
- Does NOT kill the buffer after completion -- keeps it for collection

#### New tool: `collect-results`
- `my-gptel-tool-collect-results (task-ids &optional timeout)`
- Takes a list of task IDs (space-separated or JSON array)
- Waits for all to complete (or timeout)
- Returns all responses as a combined string
- Kills buffers after collection

#### Modified `delegate` (existing)
- Keep as-is for backward compatibility (synchronous, single delegate)
- Or: make it a wrapper that calls delegate-async then collect-results with one ID

### Implementation notes
- `accept-process-output` already yields to event loop, so multiple async delegates can run concurrently in theory -- need to verify gptel doesn't serialize requests
- Each delegate buffer has its own `gptel-backend` and `gptel-model` (from Phase 2 routing), so they hit different backends in parallel
- Need to handle: partial completions, buffer death, timeout per-task

### Files
- `/root/.emacs.d/init.d/delegate_tool.el` -- add async variants
- Register both new tools in the same file

---

## Phase 5 (Later): Local Inference Fallback for Sharing

### Goal
Support running the framework with only a local Ollama instance (tier 1). For users without remote servers.

### Design
- Detect at startup: if no remote backends configured, define a local Ollama backend at `localhost:11434`
- Small model (3B-8B) suitable for weak hardware
- All agents route to local backend
- `execute_code_remote` detects no SSH config, degrades to `execute_code_local` with note
- Document minimum hardware requirements for local-only mode

### Deprioritized
- Build for the author's hardware first. Abstract later.

---

## Architecture Notes

### Why not run Ollama on tier 2 (0b.ar)?
- 64GB RAM, 16 cores, no GPU. CPU inference is slow for interesting models.
- Better used as execution sandbox: Docker, compilation, test suites, long-running processes.
- Could run a small model (3B) as fallback if needed, but not worth the complexity now.

### On the "dangerous but fun" remote execution idea
- Agent with root SSH to a VPS can do anything: spin up containers, run services, install packages.
- This is the natural extension of self-modification: the agent already modifies its own runtime (Emacs Lisp), giving it a real execution environment expands its world.
- Risk is manageable: 0b.ar is a test server, not production. SSH key restrictions and dedicated users can be added later.
- For sharing: tool detects configuration and degrades gracefully. Same code, different capability profile.

### On building for yourself first
- The framework should use all available hardware. Limiting potential because someone else's setup is simpler is the wrong optimization.
- Configuration via `defcustom` means the default can be simple (local Ollama only) while the author's config is powerful (four tiers).
- Sharing is a documentation problem, not an architecture problem. Solve it later.

### Model selection rationale
- `coder` on 8B: code generation for Emacs Lisp doesn't need a large model. 8B at q8 on GPU is fast and sufficient.
- `reviewer` on 20B: review needs more capacity to spot subtle issues.
- `researcher` on cloud 500B: synthesis and deep reasoning benefit from frontier models.
- `mccarthy` on cloud (budgeted): architectural decisions need quality. Falls back to 120B on tier 3 when cloud budget exhausted.
- Routing table is an alist -- tune by editing one variable. No restart needed if using `eval-expression`.
---

## Phase 6: Continuous Agents (NPU-Powered Autonomous Loops)

### Goal
Proactive agents that wake on a timer, perform work autonomously, and go back to sleep. Powered by local NPU inference (tier 1) for sustained low-power operation. Not request-response -- a continuous loop with state carried forward between ticks.

### Motivation
Modern laptops have NPUs (Intel NPU, Apple Neural Engine, Qualcomm Hexagon) designed for sustained low-power inference. A 3B-8B model on an NPU sips watts. Running an agent every 15 minutes all day on battery becomes economically practical. This transforms the framework from interactive tool to autonomous system.

### Architecture

#### The Continuous Agent Loop
```
Timer fires (every N minutes)
  -> Check: is previous tick still running? If yes, skip.
  -> Spawn a gptel session in a background buffer
  -> Load agent profile (e.g., "gardener", "watcher")
  -> Set backend to local Ollama (NPU, localhost:11434)
  -> Construct prompt from:
       - Agent's mission statement (from prompt.org)
       - State file: what it did last time, what changed since
       - Current context: git log, file timestamps, test results, etc.
  -> Agent runs autonomously (no human input)
  -> On completion:
       - Write results to state file (for next tick's context)
       - Log to HISTORY.log
       - If something noteworthy: notify user (D-Bus notification + *continuous-agents* buffer)
       - If nothing changed: output NO_CHANGE, stay silent
  -> Kill buffer, sleep until next tick
```

#### State Management Between Ticks
Each tick is a fresh gptel session. The agent has no memory of previous runs except what you give it.
- State file per continuous agent: `agents.d/<name>/state.json` (or `.org`)
- Contains: last run timestamp, last git commit seen, last test results, accumulated observations
- Agent reads it at start of tick, writes it at end of tick
- This is the continuity mechanism -- not a persistent process, but a series of one-shot sessions with carried state

#### Overlap Handling
- If tick N is still running when tick N+1 fires: skip the new tick
- Simple flag: `my-gptel--continuous-running-p` (buffer-local or per-agent)
- Do not queue -- skipping is safer and simpler

#### Notification Model
- `notifications-notify` (D-Bus desktop notifications) for noteworthy events
- `*continuous-agents*` buffer as a log the user can check
- Mode line indicator showing continuous agents are active
- The agent's prompt encodes the judgment of what's "noteworthy" vs "silent"
- Not everything warrants interrupting the user

### Use Cases

| Agent | Interval | Mission |
|-------|----------|---------|
| Gardener | 15-30 min | Monitor codebase. `git diff` since last check, look for warnings, check tests pass, note new TODO comments. Report only on changes. |
| Watcher | 60 min | Monitor external systems. Service health, SSL cert expiry, dependency security advisories. |
| Librarian | 30-60 min | Maintain documentation. After code changes, update docstrings, regenerate README sections, keep MEMORIES.md current across agents. |
| Scribe | On session end | Sit in on gptel sessions passively. Extract decisions, log to HISTORY, update TODO.md, file ideas into IDEAS.md. A secretary that never sleeps. |

### Design

#### Registration
```elisp
(defvar my-gptel-continuous-agents
  '(("gardener" . (:interval 900  :model "granite4.1:8b-q8_0" :backend local))
    ("watcher"  . (:interval 3600 :model "granite4.1:8b-q8_0" :backend local)))
  "Registered continuous agents and their schedules.
:interval in seconds. :backend is a symbol referencing a defined gptel backend.
:model is the Ollama model string.")
```

#### Core functions
```elisp
(defun my-gptel-start-continuous-agent (agent-name)
  "Start a continuous agent on a timer.")

(defun my-gptel-stop-continuous-agent (agent-name)
  "Stop a continuous agent's timer.")

(defun my-gptel-start-all-continuous-agents ()
  "Start all registered continuous agents.")

(defun my-gptel-stop-all-continuous-agents ()
  "Stop all continuous agents.")

(defun my-gptel--continuous-tick (agent-name)
  "Fire one tick of a continuous agent.
Spawn session, build prompt from mission + state + context,
run autonomously, capture output, update state, log, notify.")
```

#### The tick function
- Essentially the delegate spawn mechanism, but:
  - Backend is local Ollama (NPU), not the routing table
  - Prompt is auto-constructed: mission statement + state file contents + current context (e.g., `git log --since="<last-tick>"`)
  - Output goes to state file + HISTORY.log + optional notification
  - No human interaction -- fully autonomous
  - Agent decides whether to report or stay silent (prompt-encoded judgment)

#### NPU/Ollama integration
- Depends on Ollama supporting NPU offload
- Intel OpenVINO backend for Ollama: in progress
- Apple MLX serves Neural Engine
- For now, architecture doesn't depend on NPU specifically -- just needs local Ollama
- NPU makes it practical to run all day on battery
- Without NPU: works but burns CPU/GPU watts every interval (less practical for always-on)

### Files
- `/root/.emacs.d/init.d/continuous_agent.el`
- Load from `init.el`
- State files: `agents.d/<name>/state.json` (or `.org`)
- Notification buffer: `*continuous-agents*`

### Prerequisites
- [ ] Local Ollama installed on laptop (tier 1)
- [ ] Small model pulled (3B-8B, NPU-compatible)
- [ ] Verify Ollama NPU offload support for specific hardware
- [ ] Define at least one continuous agent profile (e.g., `agents.d/gardener/prompt.org`)

### Philosophical note
McCarthy's original vision of AI was programs that operate autonomously in the world, making decisions, taking action. The LISP machine was supposed to be an always-on intelligent agent, not a calculator you poke at. Request-response is the calculator. Continuous agents are the machine. The NPU makes it economically viable. Emacs provides the timer infrastructure. gptel provides the inference. The agent framework provides the profiles and tools. This is not building something new -- it's activating a mode that was always latent in the design.