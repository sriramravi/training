# Sonatype Skill — Dependency Security

## When to Use
- Adding or upgrading dependencies
- Choosing libraries
- Security audit of packages

## Rules
- Prefer “Golden Version” (best hygiene, no active CVEs)
- Reject packages with critical/high vulnerabilities
- Flag license risks (GPL/Copyleft)
- Surface breaking change risks

## Output Format
- Package name + version
- CVE details (CVSS, Severity, CWE)
- Suggested alternative if required