* AUDITOR TODO

** TODO Test auditor agent with a live delegation chain
   - Verify it delegates to reader for recon
   - Verify it routes to coder for payload crafting
   - Verify it uses reviewer for safety checks before execution
   - Verify actor writes to AUDIT_REPORT.md

** TODO Create a test target for non-destructive demos
   - Set up a local intentionally-vulnerable app (e.g., DVWA or custom)
   - Ensure it has XSS, info disclosure, misconfig examples
   - Keep it isolated from production

** TODO Verify engagement rules are enforced through delegation
   - Confirm delegates receive engagement rules in context
   - Confirm reviewer rejects destructive payloads
   - Confirm auditor asks human before any borderline technique
