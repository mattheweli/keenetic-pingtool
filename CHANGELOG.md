# keenetic-pingtool 2.0.1

## Pingtool 2.0.2 / coordinated package 2.0.8 — 2026-10-26

- Include the configured latency threshold in IPv6 ping-warning email bodies, matching IPv4. The shared renderer can now color a healthy latency green when packet loss is the reason for the warning. Threshold comparison and alert triggers are unchanged.
- Update shared Mail Layout to 1.0.1: accept standard MTR report loss fields with or without a percent marker. Normalize the displayed suffix and keep unanswered hops such as `3.|-- ??? 100.0 ...` in their original table position. Retain escaped fallback output for genuinely unsupported diagnostics and MPLS details.
- Extend regressions for actual IPv4/IPv6 alert bodies, below/exact/above-threshold colors, answered/unanswered hops, both loss formats, ordered table rows and diagnostic fallback escaping.

The manager remains **KeenTool 2.0.7**. The complete package advances to **2.0.8** solely to distribute Pingtool 2.0.2 and shared Mail Layout 1.0.1 through verified upgrades. Firewall, Traffic Manager, SMB Backup and Main Dashboard versions are unchanged. No probe algorithm, notification trigger/cooldown, cron, configuration, credentials or database policy changes.


Refresh the generated page shared UI reference for the coordinated security freshness correction. Probe, notification and history algorithms are unchanged. Rewrite the explanatory README with a synthetic Connection Monitor screenshot.

## Installation

Update through the complete verified KeenTool 2.0.5 suite. This component depends on its shared runtime/assets; do not copy isolated sources over an older installation. Existing settings, credentials, schedules and databases are preserved. See README.md and the suite installation guide. The screenshot shows actual templates with synthetic example data.

## Validation

The complete suite is checked on the exact KeenTool release commit, including configured freshness, refresh behavior, file transactions and component regression tests. These component algorithms are unchanged; this patch refreshes shared asset references and documentation. No physical-router reboot or live SMTP is claimed.


# keenetic-pingtool stable changelog

Baseline: `bba63ac0b099f4001b6f91bb7314bc704f08e238`.

- External persistent configuration; migrate supported inline preferences on upgrade. Configurable retention/display points and time-based history windows (hour/day/month/MAX), separate sample and plotted-point counts, optional latency/loss peaks and IPv4/IPv6 coverage.
- Preserve full-resolution database history according to existing retention; plotting aggregation does not replace database rows. External settings survive script replacement.
- Distinguish warning recovery from true all-probe-unreachable recovery; partial loss/latency warning clearance does not emit a WAN-reconnection email. Include WAN/family labels and explain sampled durations.
- Detect PPP transitions incrementally from existing syslog without changing syslog-ng/logrotate; independent scheduled service and retryable notifications. Shared safe email/MTR layout and common browser refresh.
- Stable 2.0.0 page/footer, English interface and uniform numeric presentation; package runtime is required.
