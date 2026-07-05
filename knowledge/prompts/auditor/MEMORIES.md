* AUDITOR MEMORIES

** Agent Purpose
- Created 2026-07-05 for non-destructive security demos/audits.
- Orchestrator agent: delegates to reader, coder, reviewer, researcher, actor.
- Designed for authorized assessments where service disruption and data modification are prohibited.
- Key distinction from ctfwizard: engagement rules enforce non-destructive demos, no data modification, no service disruption. Report-driven, not flag-driven.

** Engagement Rules Summary
- No DoS, no brute-forcing, no aggressive scanning.
- No data modification (no POST/PUT/DELETE that changes state, no SQL writes, no file uploads, no account creation).
- Non-destructive demos only: XSS alert(1), read-only SQLi (UNION SELECT version()), info disclosure, misconfig evidence.
- Evidence over exploitation: produce a professional report, not full compromise.
- Always verify payloads with reviewer before execution.

** Report Output
- Final report: /root/.emacs.d/workspace/AUDIT_REPORT.md
- Format: Executive Summary, Scope, Methodology, Findings (by severity), Limitations, Appendix.
