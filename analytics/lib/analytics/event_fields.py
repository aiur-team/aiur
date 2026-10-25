# Metadata the daemon-side metric events carry; mirrors Aiur.RunTelemetry.EventFields.
EVENT_FIELDS = (
    "from_state",
    "to_state",
    "blocker",
    "head_sha",
    "pr_number",
    "input_tokens",
    "output_tokens",
    "cached_tokens",
    "cost_amount",
    "cost_currency",
    "coverage",
)

RESOURCE_EVIDENCE = (
    "fleet_capacity_status",
    "fleet_capacity_age_ms",
    "fleet_capacity_observed_at_ms",
    "fleet_admission_signal",
    "fleet_binding_kind",
    "build_gate_enabled",
    "build_gate_status",
    "build_gate_observed_at_ms",
)
