# Security

## Reporting a vulnerability

Please don't open a public issue. Report it privately through
[GitHub's private vulnerability reporting](https://github.com/aglose/greenroom/security/advisories/new)
(the **Report a vulnerability** button on the Security tab). Include the version, steps to reproduce and what an
attacker could do with it. You'll get a reply within a week.

## Supported versions

Only the latest release gets fixes. Greenroom updates itself through Sparkle, and every update is checked against
the EdDSA key in `Resources/Info.plist` before it is installed.
