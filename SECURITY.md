# Security Policy

## Reporting a vulnerability

Please **do not** report security vulnerabilities through public GitHub issues.

Instead, use GitHub's private vulnerability reporting: go to the repository's
**Security** tab and click **Report a vulnerability** (or open
`https://github.com/KiRito02/hermex/security/advisories/new`). This opens a
private security advisory that only the maintainer can see.

Include as much of the following as you can:

- A description of the vulnerability and its impact
- Steps to reproduce, or a proof of concept
- The app version (or commit) and iOS version you tested against
- The Hermes Agent version/commit and relevant advertised capability, with
  hostnames and deployment details redacted where appropriate

Never include `API_SERVER_KEY`, Apple credentials, private keys, or live
authorization headers.

You should get an initial response within a week. Please give the maintainer a
reasonable window to ship a fix before disclosing publicly.

## Scope

This repository contains only the iOS client. Vulnerabilities in the
[Hermes Agent API Server](https://github.com/NousResearch/hermes-agent) should
be reported to that project instead. Issues with how *this app* stores bearer
credentials, talks to the server, gates capabilities, or handles untrusted
server responses are in scope here.
