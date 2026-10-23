# keenetic-pingtool 2.0.0

Baseline: `bba63ac0b099f4001b6f91bb7314bc704f08e238`.

- External persistent configuration; migrate supported inline preferences on upgrade. Configurable retention/display points and time-based history windows (hour/day/month/MAX), separate sample and plotted-point counts, optional latency/loss peaks and IPv4/IPv6 coverage.
- Preserve full-resolution database history according to existing retention; plotting aggregation does not replace database rows. External settings survive script replacement.
- Distinguish warning recovery from true all-probe-unreachable recovery; partial loss/latency warning clearance does not emit a WAN-reconnection email. Include WAN/family labels and explain sampled durations.
- Detect PPP transitions incrementally from existing syslog without changing syslog-ng/logrotate; independent scheduled service and retryable notifications. Shared safe email/MTR layout and common browser refresh.
- Stable 2.0.0 page/footer, English interface and uniform numeric presentation; package runtime is required.

## Installation and compatibility

Install/update through the complete KeenTool 2.0.0 suite asset. Component archives require the coordinated shared runtime; do not replace isolated scripts over older installations. Existing settings, credentials, databases and upgrade schedules are preserved. Read the suite docs/INSTALL.md and SECURITY.md.

## Known feed limitation

IPdeny IPv6 KP may return HTTP 404; incomplete candidates retain the installed GeoBlock6 list. Cached installation time is not source freshness. This is reported explicitly, not silently bypassed.

## Validation

See suite docs/VALIDATION.md for isolated regression results and the live-router acceptance steps that remain before publication. This prepared release is a draft; no router reboot or public deployment is claimed.
