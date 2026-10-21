# Security

NotchBar sits between coding agents and your Mac, and it can approve commands. Security reports are taken seriously.

## Reporting a vulnerability

**Please don't open a public issue.** Report it privately instead:
[github.com/mumbaitrip2022/notchma/security/advisories/new](https://github.com/mumbaitrip2022/notchma/security/advisories/new)

Include what you found, how to reproduce it, and what an attacker could do with it. You'll get a reply within a few days, and credit in the release notes if you'd like.

## Supported versions

Only the latest release gets security fixes. NotchBar updates itself, so most people are on it within a day.

## What's in scope

- Anything that lets a request be approved without you, or a destructive command skip the "Destructive" warning
- The app's socket (`~/Library/Application Support/NotchBar/nb.sock`, readable only by you)
- The hook helper and the changes it makes to agent settings files
- The updater: downloading, verifying (GitHub's SHA-256, bundle id, version, code signature) and installing updates
- Data leaving your Mac (the only request should be the daily update check)
