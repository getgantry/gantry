# Security Policy

## Supported versions

Security fixes are provided for the latest released version of Gantry. Please
update to the most recent release before reporting an issue.

## Reporting a vulnerability

Please do not report security vulnerabilities through public GitHub issues.

Instead, use GitHub's private vulnerability reporting for this repository:
open the **Security** tab and choose **Report a vulnerability** to open a
private security advisory. This creates a confidential channel between you and
the maintainers.

Please include enough detail to reproduce the issue, such as the affected
version, your environment, and step-by-step instructions. You will receive a
response acknowledging the report, and you will be kept informed as the issue is
investigated and addressed.

## How Gantry handles secrets

A few notes on the security model that are useful context when assessing
reports:

- **SSH credentials** (passwords and key passphrases) are stored in the macOS
  Keychain, not in plain-text configuration files. Gantry reads them on demand
  through the system Keychain APIs.
- **Host key verification** uses a trust-on-first-use (TOFU) model. The first
  time Gantry connects to an SSH host, it records that host's key fingerprint.
  On later connections the presented key is compared against the stored one; a
  mismatch is treated as a potential man-in-the-middle situation and surfaced to
  the user rather than silently accepted. This mirrors the behavior of the
  OpenSSH `known_hosts` mechanism.
