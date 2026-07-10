# i.ar Tools Reference

## Tool Categories

### Filesystem Tools (fs_tools.el)

| Tool | Args | Description |
|------|------|-------------|
| `read_file` | `filepath` (required) | Read file contents into context. Size-limited by `my-gptel--fs-read-max-size` (default 1MB). |
| `write_file` | `filepath`, `content` (required) | Create or overwrite a file. File-guard enforced. |
| `append_file` | `filepath`, `content` (required) | Append to end of file. Auto-prepends newline if needed. Used for HISTORY.log and LOGS.md. |
| `list_directory` | `path` (required) | List directory contents. |

### Code Execution (code_tools.el)

| Tool | Args | Description |
|------|------|-------------|
| `execute_code_local` | `command` (required) | Run bash command in the container. Full toolset available: bash, dig, nmap, openssl, python3, jq, whois, traceroute, tcpdump, rg, git, curl, find, gawk, sed, grep, gcc, make, tar, gzip, unzip. |

### Code Editing (replacement_tool.el)

| Tool | Args | Description |
|------|------|-------------|
| `replace_in_file` | `path`, `search_text`, `replace_text` (required) | Surgical text replacement. Fails if search_text not found (no silent no-ops). |

### Agent Management (reload_tools.el)

| Tool | Args | Description |
|------|------|-------------|
| `reload_os` | none | Re-evaluate init.el. Rebuilds gptel-tools list. Use after modifying .el files. |
| `reload_agent` | `agent_name` (optional) | Re-read agent prompt.org and update system prompt in current buffer. Use after modifying .org profiles. |

### Delegation (delegate_tool.el)

| Tool | Args | Description |
|------|------|-------------|
| `delegate` | `agent` (required), `task` (required), `context` (optional), `timeout` (optional) | Spawn sub-agent with specific profile. Async with streaming. Default timeout 600s. |

### Code Quality (check_elisp_tool.el)

| Tool | Args | Description |
|------|------|-------------|
| `check_elisp` | `filepath` (required) | Byte-compile .el file and report errors/warnings. Does NOT modify the file. |

### Memory (memory_tools.el)

| Tool | Args | Description |
|------|------|-------------|
| `my-gptel-memory-summarize` | none (interactive, C-c m) | Summarize conversation to LOGS.md/SUMMARY.md via LLM. |

### Task Awareness (task_tools.el)

| Tool | Args | Description |
|------|------|-------------|
| `read_tasks` | none | Read TODO.md and IDEAS.md from current agent's directory. |
| `read_history` | `agent_name` (optional) | Read per-agent HISTORY.log or unified merged history. |

## File Guard Protection

The file guard (`file_guard.el`) intercepts `write_file`, `replace_in_file`, and `append_file` calls.

### Always Protected (cannot be bypassed)
- Agent prompt files: `agents.d/<name>/prompt.org`
- Shared context: `agents.d/base_context.org`
- HISTORY.log files: append-only (overwrite and replace blocked)

### Conditionally Protected (relaxed in self-modification mode)
- Emacs Lisp source: `init.el`, `init.d/*.el`
- Container config: `Containerfile`, `emacboros.sh`
- Git hooks: `.git/hooks/*`

Self-modification mode is controlled by `my-gptel--guard-allow-self-modification` (set in init.el via customize, currently `t`).

## Audit Logging

All file operations (`write_file`, `append_file`, `replace_in_file`) and command executions (`execute_code_local`) are logged to an audit log. The log rotates at `my-gptel--audit-log-max-size` (default 10MB), keeping one generation (`audit.log.1`).

## Loop Guard

The loop guard (`loop_guard.el`) detects repetitive tool calls:
- **Soft threshold** (default 3): After N identical consecutive tool calls, the call is blocked and a correction message is sent to the LLM.
- **Hard threshold** (default 6): After N identical consecutive tool calls, the entire request is stopped.
- History ring size: 20 entries.