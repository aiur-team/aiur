# Frozen control maps from 1377d2f32fb64e1d171c898cbb811a63fb072859.
pending = %{
  status: :requested,
  action: :pause,
  protocol_version: 1,
  request_id: "pause-r7",
  expected_status: :working,
  tracker_identity: %{owner: "aiur-team", reason: nil, status: :joinable, version: 1, identifier: "3464", kind: :github, repository: "aiur", provider_id: "42"},
  generation: "r7",
  issue_id: "42",
  requester: :automatic,
  expiry: nil,
  accepted_at: nil,
  expected_version: 0,
  requested_at: ~U[2026-10-01 00:00:00Z],
  rejection: nil,
  applied_at: nil,
  rejected_at: nil
}

p0 = %{
  status: :paused,
  can_interrupt: true,
  safe_checkpoints: [:notification, :tool_result],
  immediate_delivery: false,
  queue_depth: 0,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint, :interrupt],
  unit_control: :request_only,
  pending_control: nil
}

p1 = %{
  status: :working,
  can_interrupt: true,
  safe_checkpoints: [],
  immediate_delivery: false,
  queue_depth: 0,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint, :interrupt],
  unit_control: :request_only,
  pending_control: nil
}

p2 = %{
  status: :paused,
  can_interrupt: false,
  safe_checkpoints: [],
  immediate_delivery: false,
  queue_depth: 0,
  recent_controls: [
    pending
  ],
  latest_control: pending,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint],
  unit_control: :request_only,
  pending_control: pending
}

p3 = %{
  status: :paused,
  can_interrupt: true,
  safe_checkpoints: [],
  immediate_delivery: true,
  queue_depth: 0,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:immediate],
  unit_control: :request_only,
  pending_control: nil
}

p4 = %{
  status: :working,
  can_interrupt: true,
  safe_checkpoints: [:notification, :tool_result],
  immediate_delivery: false,
  queue_depth: 0,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint, :interrupt],
  unit_control: :request_only,
  pending_control: nil
}

p5 = %{
  status: :paused,
  can_interrupt: true,
  safe_checkpoints: [:notification],
  immediate_delivery: false,
  queue_depth: 0,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint, :interrupt],
  unit_control: :request_only,
  pending_control: nil
}

p6 = %{
  status: :paused,
  can_interrupt: true,
  safe_checkpoints: [],
  immediate_delivery: false,
  queue_depth: 0,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint, :interrupt],
  unit_control: :request_only,
  pending_control: nil
}

p7 = %{
  status: :paused,
  can_interrupt: false,
  safe_checkpoints: [:notification, :tool_result],
  immediate_delivery: false,
  queue_depth: 0,
  recent_controls: [
    pending
  ],
  latest_control: pending,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint],
  unit_control: :request_only,
  pending_control: pending
}

p8 = %{
  status: :paused,
  can_interrupt: true,
  safe_checkpoints: [:notification, :tool_result],
  immediate_delivery: false,
  queue_depth: 0,
  recent_controls: [
    pending
  ],
  latest_control: pending,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint, :interrupt],
  unit_control: :request_only,
  pending_control: pending
}

p9 = %{
  status: :paused,
  can_interrupt: true,
  safe_checkpoints: [],
  immediate_delivery: false,
  queue_depth: 0,
  recent_controls: [
    pending
  ],
  latest_control: pending,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint, :interrupt],
  unit_control: :request_only,
  pending_control: pending
}

p10 = %{
  status: :working,
  can_interrupt: false,
  safe_checkpoints: [],
  immediate_delivery: false,
  queue_depth: 0,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint],
  unit_control: :request_only,
  pending_control: nil
}

p11 = %{
  status: :working,
  can_interrupt: true,
  safe_checkpoints: [],
  immediate_delivery: true,
  queue_depth: 0,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:immediate],
  unit_control: :request_only,
  pending_control: nil
}

p12 = %{
  status: :paused,
  can_interrupt: false,
  safe_checkpoints: [],
  immediate_delivery: false,
  queue_depth: 0,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint],
  unit_control: :request_only,
  pending_control: nil
}

p13 = %{
  status: :working,
  can_interrupt: false,
  safe_checkpoints: [:notification, :tool_result],
  immediate_delivery: false,
  queue_depth: 0,
  recent_controls: [
    pending
  ],
  latest_control: pending,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint],
  unit_control: :request_only,
  pending_control: pending
}

p14 = %{
  status: :sleeping,
  can_interrupt: true,
  safe_checkpoints: [],
  immediate_delivery: true,
  queue_depth: 0,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:immediate],
  unit_control: :request_only,
  pending_control: nil
}

p15 = %{
  status: :working,
  can_interrupt: true,
  safe_checkpoints: [:notification],
  immediate_delivery: false,
  queue_depth: 0,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint, :interrupt],
  unit_control: :request_only,
  pending_control: nil
}

p16 = %{
  status: :paused,
  can_interrupt: true,
  safe_checkpoints: [:notification],
  immediate_delivery: false,
  queue_depth: 0,
  recent_controls: [
    pending
  ],
  latest_control: pending,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint, :interrupt],
  unit_control: :request_only,
  pending_control: pending
}

p17 = %{
  status: :working,
  can_interrupt: true,
  safe_checkpoints: [],
  immediate_delivery: false,
  queue_depth: 0,
  recent_controls: [
    pending
  ],
  latest_control: pending,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint, :interrupt],
  unit_control: :request_only,
  pending_control: pending
}

p18 = %{
  status: :working,
  can_interrupt: false,
  safe_checkpoints: [:notification, :tool_result],
  immediate_delivery: false,
  queue_depth: 0,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint],
  unit_control: :request_only,
  pending_control: nil
}

p19 = %{
  status: :working,
  can_interrupt: true,
  safe_checkpoints: [],
  immediate_delivery: true,
  queue_depth: 0,
  recent_controls: [
    pending
  ],
  latest_control: pending,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:immediate],
  unit_control: :request_only,
  pending_control: pending
}

p20 = %{
  status: :sleeping,
  can_interrupt: true,
  safe_checkpoints: [],
  immediate_delivery: false,
  queue_depth: 0,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint, :interrupt],
  unit_control: :request_only,
  pending_control: nil
}

p21 = %{
  status: :sleeping,
  can_interrupt: true,
  safe_checkpoints: [:notification, :tool_result],
  immediate_delivery: false,
  queue_depth: 0,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint, :interrupt],
  unit_control: :request_only,
  pending_control: nil
}

p22 = %{
  status: :working,
  can_interrupt: false,
  safe_checkpoints: [],
  immediate_delivery: false,
  queue_depth: 0,
  recent_controls: [
    pending
  ],
  latest_control: pending,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint],
  unit_control: :request_only,
  pending_control: pending
}

p23 = %{
  status: :sleeping,
  can_interrupt: false,
  safe_checkpoints: [],
  immediate_delivery: false,
  queue_depth: 0,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint],
  unit_control: :request_only,
  pending_control: nil
}

p24 = %{
  status: :sleeping,
  can_interrupt: false,
  safe_checkpoints: [:notification, :tool_result],
  immediate_delivery: false,
  queue_depth: 0,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint],
  unit_control: :request_only,
  pending_control: nil
}

p25 = %{
  status: :paused,
  can_interrupt: false,
  safe_checkpoints: [:notification, :tool_result],
  immediate_delivery: false,
  queue_depth: 0,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint],
  unit_control: :request_only,
  pending_control: nil
}

p26 = %{
  status: :sleeping,
  can_interrupt: true,
  safe_checkpoints: [:notification],
  immediate_delivery: false,
  queue_depth: 0,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint, :interrupt],
  unit_control: :request_only,
  pending_control: nil
}

p27 = %{
  status: :working,
  can_interrupt: true,
  safe_checkpoints: [:notification, :tool_result],
  immediate_delivery: false,
  queue_depth: 0,
  recent_controls: [
    pending
  ],
  latest_control: pending,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint, :interrupt],
  unit_control: :request_only,
  pending_control: pending
}

p28 = %{
  status: :working,
  can_interrupt: true,
  safe_checkpoints: [:notification],
  immediate_delivery: false,
  queue_depth: 0,
  recent_controls: [
    pending
  ],
  latest_control: pending,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:checkpoint, :interrupt],
  unit_control: :request_only,
  pending_control: pending
}

p29 = %{
  status: :paused,
  can_interrupt: true,
  safe_checkpoints: [],
  immediate_delivery: true,
  queue_depth: 0,
  recent_controls: [
    pending
  ],
  latest_control: pending,
  accepts_operator_messages: true,
  accepted_delivery_policies: [:immediate],
  unit_control: :request_only,
  pending_control: pending
}

%{
  {"claude", :paused} => p5,
  {"claude", :self_paused} => p5,
  {"claude", :self_paused_pending} => p16,
  {"claude", :sleeping} => p26,
  {"claude", :working_active} => p15,
  {"claude", :working_idle} => p15,
  {"claude", :working_pending} => p28,
  {"claude-repl", :paused} => p3,
  {"claude-repl", :self_paused} => p3,
  {"claude-repl", :self_paused_pending} => p29,
  {"claude-repl", :sleeping} => p14,
  {"claude-repl", :working_active} => p11,
  {"claude-repl", :working_idle} => p11,
  {"claude-repl", :working_pending} => p19,
  {"codex", :paused} => p0,
  {"codex", :self_paused} => p0,
  {"codex", :self_paused_pending} => p8,
  {"codex", :sleeping} => p21,
  {"codex", :working_active} => p4,
  {"codex", :working_idle} => p4,
  {"codex", :working_pending} => p27,
  {"fake", :paused} => p12,
  {"fake", :self_paused} => p12,
  {"fake", :self_paused_pending} => p2,
  {"fake", :sleeping} => p23,
  {"fake", :working_active} => p10,
  {"fake", :working_idle} => p10,
  {"fake", :working_pending} => p22,
  {"kimi", :paused} => p25,
  {"kimi", :self_paused} => p25,
  {"kimi", :self_paused_pending} => p7,
  {"kimi", :sleeping} => p24,
  {"kimi", :working_active} => p18,
  {"kimi", :working_idle} => p18,
  {"kimi", :working_pending} => p13,
  {"muse", :paused} => p6,
  {"muse", :self_paused} => p6,
  {"muse", :self_paused_pending} => p9,
  {"muse", :sleeping} => p20,
  {"muse", :working_active} => p1,
  {"muse", :working_idle} => p1,
  {"muse", :working_pending} => p17
}
