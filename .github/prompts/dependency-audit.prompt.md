# Dependency Security Audit

Analyze the provided dependencies using Sonatype.

Steps:
1. Identify all dependencies
2. Query Sonatype MCP for:
   - Vulnerabilities (CVE)
   - CVSS score
   - License risks
3. Recommend:
   - Safe versions (Golden Version)
   - Safer alternatives if needed

Output:
- Package name
- Current version
- Risk (CVSS, CWE)
- Recommended version
- License risk (if any)