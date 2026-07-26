# Security Policy

## Reporting a vulnerability

Please **do not** report security vulnerabilities through public GitHub issues.

Instead, use GitHub's private vulnerability reporting: go to the repository's
**Security** tab and click **Report a vulnerability** (or open
`https://github.com/KiRito02/hermes-nest/security/advisories/new`). This opens a
private security advisory that only the maintainer can see.

Include as much of the following as you can:

- A description of the vulnerability and its impact
- Steps to reproduce, or a proof of concept
- The app version (or commit) and iOS version you tested against
- The App and Companion versions/commits, Hermes Agent version/commit, and
  relevant advertised capabilities, with hostnames and deployment details
  redacted where appropriate

Never include Companion device credentials, pairing secrets, `API_SERVER_KEY`,
Apple credentials, private keys, live authorization headers, Memory content, or
uploaded files.

You should get an initial response within a week. Please give the maintainer a
reasonable window to ship a fix before disclosing publicly.

## Scope

This repository owns the iOS App and planned NAS Companion. Vulnerabilities in
the underlying
[Hermes Agent API Server](https://github.com/NousResearch/hermes-agent) should
be reported upstream. Pairing, device authentication/revocation, Gateway key
custody, proxying, capability merging, workspace confinement, upload safety,
Memory mutations, App Keychain storage, and handling of untrusted responses are
in scope here.
