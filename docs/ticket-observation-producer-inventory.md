# Ticket observation producer inventory (V1)

BO-017 attaches `%Aiur.TicketObservation{version: 1}` at the shared
`Aiur.Events.Publisher` boundary. Existing `id`, `topic`, and payload fields
remain unchanged for subscribers that do not use Build Order records.

| Producer family | Observations | Trusted attachment | Compatibility behavior |
| --- | --- | --- | --- |
| `Aiur.AgentRunner.ToolExecutor` event callback | `progress`, `progress.checkin`, and `progress.phase` | BO-004 issue identity; boot run, session, invocation provenance; source occurrence time | Unknown event names remain published but have an unclassified, attribute-free envelope. |
| `Aiur.AgentRunner.ToolExecutor` alert callback through `Aiur.Alerts` | `phase.<stage>.<start\|end>` active-stage signals and bounded alert evidence | BO-004 issue identity; boot run, session, invocation provenance; source occurrence time | Stage fields are typed; generic alerts retain only safe severity and actionable state. |
| Other `Publisher.publish/3` and `publish_persisted/4` callers | Legacy/unmigrated events | None | Envelope is `:unattributed`; it cannot become joinable from topic, ticket number, workspace path, workflow, or payload prose. |

## V1 contract

`tracker_identity` is joinable only when the BO-004 configured-repository
identity validates. Source/run/session provenance is separate from identity.
`occurred_at` is producer time and `observed_at` is publisher ingestion time.
Absent or malformed producer timestamps stay unknown; the Publisher records
`observed_at` only when it ingests the event.

The envelope holds only typed, bounded attributes. It excludes event message,
reason prose, raw tool/model output, local paths, credentials, capability URLs,
and account data. Publisher topics continue to be routing-only text.

## Consumer window

The V1 envelope is additive. Existing PubSub, IssueLog, event-bus, and routing
subscribers can ignore `ticket_observation`. BO-005 may consume joinable V1
observations for its activity projection; it must not qualify an unattributed
observation. BO-019 remains responsible for any bounded recent-history policy.
