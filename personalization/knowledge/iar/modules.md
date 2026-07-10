# i.ar Emacs Modules

All Emacs Lisp modules live in `init.d/` and are organized into subdirectories by purpose. The auto-discovery scans `init.d/dynamic/` for new modules created by agents (e.g., darwin). When a dynamic module proves useful, it is promoted to the appropriate subdirectory and added to init.el's explicit load list.

## Module Inventory

### Core Infrastructure

| Module | Purpose |
|--------|---------|
| `init.el` | Entry point. Loads all modules explicitly, then auto-discovers the rest. Sets `load-prefer-newer t` to avoid stale byte-compiled code. |
| `metaconfig/parameters.el` | Central parameter configuration. All tunable parameters (delegate depth, darwin cycle limits, loop guard thresholds, memory limits, file read limits, audit log rotation). Loaded before any init.d module. |
| `metaconfig/gptel.el` | Ollama backend configuration. Defines models, host, request params. |
| `locale.el` | UTF-8 locale configuration. Must load first. |
| `package_setup.el` | Package manager setup (MELPA, use-package). |
| `ui_cleanup.el` | UI cleanup (no toolbar, no scrollbar, no menu bar). |
| `evil_mode.el` | Evil mode (vim keybindings in Emacs). |
| `gptel_setup.el` | Loads gptel package and applies metaconfig/gptel.el settings. |

### Agent System

| Module | Purpose |
|--------|---------|
| `agent_loader.el` | **C-c a** -- Interactive agent profile loader. Discovers `agents.d/agents/<name>/prompt.org`, expands `#+INCLUDE` directives via org-export, sets `gptel-system-prompt`. Tracks current agent name and file. Resets knowledge state on agent switch. Reports prompt size on load. |
| `knowledge_loader.el` | **C-c k** -- Interactive knowledge folder/file loader. Reads `.md`/`.org` files from `knowledge/<folder>/`, appends to system prompt with delimiters. Idempotent (same knowledge reload is no-op). Replaces previous knowledge block, preserves personality. **C-c p** -- Prompt size info (chars + approximate tokens). |
| `delegate_tool.el` | Async multi-agent delegation. Spawns sub-agent buffers with streaming output mirrored to parent. Timeout handling, max depth limiting, unknown tool blocking, text-only turn re-prompting. |
| `prompt_loader.el` | Loads prompt templates from `agents.d/common/*.org`. Used by delegate_tool, darwin_cycle, loop_guard, memory_tools. |
| `reload_tools.el` | **reload_os** tool: re-evaluates init.el, rebuilds gptel-tools. **reload_agent** tool: re-reads current agent's prompt.org. |
| `memory_tools.el` | **C-c m** -- Memory summarization. Sends conversation to LLM for summarization, stores in LOGS.md/SUMMARY.md. |
| `task_tools.el` | Reads TODO.md and IDEAS.md from agent directory. Reads unified HISTORY.log. |
| `darwin_cycle.el` | Autonomous agent cycle runner. Darwin mode: agent runs in a loop, making one change per cycle, testing, logging, sleeping. Has its own cycle buffer, timeout, max turns, continue prompting. |

### Filesystem and Code Tools

| Module | Purpose |
|--------|---------|
| `fs_tools.el` | Filesystem tools for gptel: `read_file`, `write_file`, `append_file`, `list_directory`. Size-limited reads. |
| `code_tools.el` | `execute_code_local` tool: runs bash commands in the container. Full toolset: bash, dig, nmap, openssl, python3, jq, git, curl, rg, gcc, make, etc. |
| `replacement_tool.el` | `replace_in_file` tool: surgical text replacement in files. |
| `check_elisp_tool.el` | `check_elisp` tool: byte-compiles .el files and reports errors/warnings without modifying them. |

### Security and Safety

| Module | Purpose |
|--------|---------|
| `file_guard.el` | Protected path enforcement. Two tiers: always-protected (agent prompts, base context, history logs) and conditionally-protected (.el files, Containerfile, git hooks). Self-modification mode relaxes tier 2 but never tier 1. |
| `audit_log.el` | Audit logging for all file operations and command executions. Rotates at configurable size. |
| `loop_guard.el` | Detects repetitive tool call loops. Soft threshold: blocks and warns. Hard threshold: stops the request entirely. |
| `output_sanitizer.el` | Output filtering for tool results. |

### Session Management

| Module | Purpose |
|--------|---------|
| `iar_quit.el` | Session-aware shutdown. Summarizes before killing Emacs. |

## Keybindings

| Key | Command | Description |
|-----|---------|-------------|
| C-c a | `my-gptel-load-agent` | Load agent personality |
| C-c k | `my-gptel-load-knowledge` | Load knowledge folder/file |
| C-c p | `my-gptel-prompt-info` | Show prompt size info |
| C-c m | `my-gptel-memory-summarize` | Summarize conversation to memory |

## Agent Profile Structure

Each agent lives in `prompts/agents/<name>/` (bind-mounted to `/root/.emacs.d/agents.d/agents/`):

```
agents.d/agents/<name>/
  prompt.org      -- Agent personality (loaded by C-c a, #+INCLUDE expanded)
  LOGS.md         -- Semantic session notes (included in prompt via #+INCLUDE)
  SUMMARY.md      -- Compressed memory summary (included in prompt via #+INCLUDE)
  HISTORY.log     -- Operational log (append-only, file-guard protected)
  TODO.md         -- Optional: pending tasks
  IDEAS.md        -- Optional: project ideas
```

The `prompt.org` file typically ends with:
```
#+INCLUDE: "LOGS.md"
#+INCLUDE: "SUMMARY.md"
```

These are expanded by `org-export-expand-include-keyword` when the profile is loaded, so the agent sees its memory as part of its system prompt.

## Shared Context

`prompts/base_context.org` contains shared context inherited by all agents (bind-mounted to `agents.d/base_context.org`). Individual agent prompts include it via:
```
#+INCLUDE: "../../base_context.org"
```

## Prompt Templates

`prompts/common/` contains prompt templates used by the system (not user-facing, bind-mounted to `agents.d/common/`):
- `delegated_task.org` -- Template for delegate task prompts
- `delegate_continue.org` -- Re-prompt for delegates that narrate instead of acting
- `darwin_cycle.org` -- Darwin cycle prompt
- `darwin_cycle_continue.org` -- Darwin cycle continuation
- `memory_summarizer.org` -- Memory summarization prompt
- `loop_soft_block.org` -- Loop guard soft block message
- `loop_hard_stop.org` -- Loop guard hard stop message
- `unknown_tool.org` -- Unknown tool error message