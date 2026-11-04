# Security policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report privately through GitHub: on this repository go to **Security → Report a vulnerability**
(GitHub private vulnerability reporting). Include what you found, how to reproduce it, and the app commit and
Hermes Agent version you used. Do not include real tokens or API keys; redact them.

This is a volunteer project: expect an acknowledgement on a best-effort basis, not a guaranteed response time.

## Scope

In scope: this app and `HermesGatewayKit`, for example

- leaking the backend session token or provider credentials (logs, error messages, files, screenshots),
- the app connecting to or trusting a backend it should reject,
- the app deleting or changing Hermes data it did not create.

Out of scope: vulnerabilities in Hermes Agent itself. Report those to the
[Hermes Agent project](https://github.com/NousResearch/hermes-agent).

## Supported versions

Only the latest `main` is supported. There are no release builds yet.
