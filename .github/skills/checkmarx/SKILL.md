# Checkmarx Skill — Code & IaC Security

## When to Use
- Security-sensitive code
- API handling / user inputs
- Infrastructure as Code

## Vulnerability Coverage
- SQLi, XSS, SSRF, XXE
- Command injection, path traversal
- Insecure deserialization

## Rules
- Prefer MCP "Best Fix" patterns
- Analyze data flow before suggesting fixes
- Always scan for secrets in code

## IaC Checks
- Public storage exposure
- Open security groups
- Root containers
- Misconfigured policies