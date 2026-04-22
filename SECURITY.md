# Security Policy

## Supported versions

The gem is pre-1.0. Only the latest released version receives security fixes — please upgrade rather than expecting backports to older releases.

## Reporting a vulnerability

Please **do not open a public GitHub issue** for security reports.

Email **sergey@mm.st** with:

- A description of the issue and its potential impact
- Steps to reproduce (a minimal proof-of-concept is ideal)
- The affected version(s)
- Any suggested mitigation or fix

You will receive an acknowledgment within **72 hours**. I will work with you on a disclosure timeline — typically a fix plus a coordinated release within 14 days for confirmed vulnerabilities, longer if the issue is complex.

## Scope

In scope:

- Vulnerabilities in the gem's middleware, parsers, storage adapters, dashboard controllers, or generators
- Data-exposure issues (unintended persistence of prompt content, API keys, or response bodies)
- Injection, auth-bypass, or privilege-escalation in the mounted dashboard

Out of scope:

- Issues in third-party dependencies (report those upstream; mention them here only if this gem's usage pattern creates the vulnerability)
- Missing security hardening recommendations that are not vulnerabilities (open a regular issue instead)
- Social engineering or physical attacks

## Credit

Reporters who follow this policy will be credited in the release notes for the fix unless they request anonymity.
