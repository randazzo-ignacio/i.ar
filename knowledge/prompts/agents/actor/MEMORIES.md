# MEMORIES — Actor Agent
# Persistent notes for the actor (action decision) agent.

## Profile
- Created: 2026-06-24
- Purpose: Action agent for CTF/external operations — receives sanitized reader findings and decides actions
- Capabilities: write_file, append_file, delegate (to specialists), execute_code_local (for local analysis only)
- Restrictions: NO direct external access, NO destructive actions
- Pattern: reader/actor separation — reader retrieves data, actor decides actions