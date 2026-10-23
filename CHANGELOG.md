# keenetic-pingtool stable changelog

Baseline: `bba63ac0b099f4001b6f91bb7314bc704f08e238`.

- External persistent configuration; migrate supported inline preferences on upgrade. Configurable retention/display points and time-based history windows (hour/day/month/MAX), separate sample and plotted-point counts, optional latency/loss peaks and IPv4/IPv6 coverage.
- Preserve full-resolution database history according to existing retention; plotting aggregation does not replace database rows. External settings survive script replacement.
- Distinguish warning recovery from true all-probe-unreachable recovery; partial loss/latency warning clearance does not emit a WAN-reconnection email. Include WAN/family labels and explain sampled durations.
- Detect PPP transitions incrementally from existing syslog without changing syslog-ng/logrotate; independent scheduled service and retryable notifications. Shared safe email/MTR layout and common browser refresh.
- Stable 2.0.0 page/footer, English interface and uniform numeric presentation; package runtime is required.
