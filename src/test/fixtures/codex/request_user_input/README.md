# Recorded request frames

These JSON files are byte-for-byte copies from
`docs/research/aiur-mobile-and-platform/bucket-2-platform/MP-E2/tickets/MP-E2-C4-T00-fixtures/`.
See that directory's companion findings for the recording procedure and sanitization.

The recorded approval is a `commandExecution/requestApproval`, not an approval-style
user-input question. Both recorded user-input requests have `isSecret: false`.
The tests explicitly derive approval labels and `secret: true` from the normalized
recording; neither variant is presented as a real captured frame.

The two-question recording includes a one-option question, accepted by Codex.
