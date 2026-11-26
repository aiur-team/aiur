# Multi-project gateways: plan id to issue

Filed 2026-11-06 from [the plan](../2026-11-06-multi-project-gateways.md). After filing, the GitHub issue is the
source of truth for each ticket; edits go to the issue, not to the ticket files. `R` ids are `kind:research` deep
dives that block the matching implementation ticket.

| Plan id | Issue | Title |
|---|---|---|
| MPG-001R | #7581 | Research: Expose the gateway identity on every daemon response |
| MPG-001 | #7603 | Expose the gateway identity on every daemon response |
| MPG-002R | #7582 | Research: Add projects, capacity and coordination sections to the machine config |
| MPG-002 | #7604 | Add projects, capacity and coordination sections to the machine config |
| MPG-101 | #7583 | Characterise GitHub ref compare-and-set for ticket ownership |
| MPG-102R | #7605 | Research: Read and write ticket ownership refs through the GitHub client |
| MPG-102 | #7632 | Read and write ticket ownership refs through the GitHub client |
| MPG-103R | #7606 | Research: Require durable ownership before every dispatch |
| MPG-103 | #7639 | Require durable ownership before every dispatch |
| MPG-104R | #7607 | Research: Project ownership as a gateway label and skip ambiguous tickets |
| MPG-104 | #7649 | Project ownership as a gateway label and skip ambiguous tickets |
| MPG-105R | #7608 | Research: Stop a stale owner before pushes and pull requests |
| MPG-105 | #7650 | Stop a stale owner before pushes and pull requests |
| MPG-106R | #7609 | Research: Show and transfer ticket ownership from the CLI |
| MPG-106 | #7640 | Show and transfer ticket ownership from the CLI |
| MPG-107R | #7610 | Research: Migrate today's label prefixes to ownership records |
| MPG-107 | #7656 | Migrate today's label prefixes to ownership records |
| MPG-108R | #7611 | Research: Make the Postgres lease an optimisation under durable ownership |
| MPG-108 | #7651 | Make the Postgres lease an optimisation under durable ownership |
| MPG-109R | #7612 | Research: Prove two daemons share one repository without duplicate work |
| MPG-109 | #7666 | Prove two daemons share one repository without duplicate work |
| MPG-201R | #7584 | Research: Pin gateway identity in the remote registry |
| MPG-201 | #7633 | Pin gateway identity in the remote registry |
| MPG-202R | #7585 | Research: Add the --gateway selector to every remote-capable command |
| MPG-202 | #7641 | Add the --gateway selector to every remote-capable command |
| MPG-203R | #7586 | Research: Close the remote command gate gaps |
| MPG-203 | #7613 | Close the remote command gate gaps |
| MPG-204R | #7587 | Research: Give remote writes request ids and replay-safe retries |
| MPG-204 | #7614 | Give remote writes request ids and replay-safe retries |
| MPG-205R | #7588 | Research: Split write scope into permission categories bound to a peer |
| MPG-205 | #7634 | Split write scope into permission categories bound to a peer |
| MPG-206R | #7589 | Research: Grant, revoke and inspect peer permissions on the receiving gateway |
| MPG-206 | #7642 | Grant, revoke and inspect peer permissions on the receiving gateway |
| MPG-207R | #7590 | Research: Answer unauthenticated hello and list discoverable gateways |
| MPG-207 | #7652 | Answer unauthenticated hello and list discoverable gateways |
| MPG-208R | #7591 | Research: Enrol a peer with a one-time invite |
| MPG-208 | #7657 | Enrol a peer with a one-time invite |
| MPG-209R | #7592 | Research: Show gateway status from the CLI |
| MPG-209 | #7658 | Show gateway status from the CLI |
| MPG-210R | #7593 | Research: Prove registered gateways and remote control between PC and Nook |
| MPG-210 | #7667 | Prove registered gateways and remote control between PC and Nook |
| MPG-301 | #7594 | Decide the multi-project process model |
| MPG-302R | #7615 | Research: Give each process a project context that config reads |
| MPG-302 | #7635 | Give each process a project context that config reads |
| MPG-303R | #7616 | Research: Register the orchestrator per project |
| MPG-303 | #7643 | Register the orchestrator per project |
| MPG-304R | #7617 | Research: Register the workflow, queue, feature and snapshot stores per project |
| MPG-304 | #7644 | Register the workflow, queue, feature and snapshot stores per project |
| MPG-305R | #7618 | Research: Register the remaining per-project singletons |
| MPG-305 | #7645 | Register the remaining per-project singletons |
| MPG-306R | #7619 | Research: Boot one project tree per configured project |
| MPG-306 | #7653 | Boot one project tree per configured project |
| MPG-307R | #7620 | Research: Share machine capacity across projects |
| MPG-307 | #7659 | Share machine capacity across projects |
| MPG-308R | #7621 | Research: Pause, reload and hand off one project without touching others |
| MPG-308 | #7660 | Pause, reload and hand off one project without touching others |
| MPG-309R | #7622 | Research: Key the daemon by gateway and migrate per-repository state |
| MPG-309 | #7661 | Key the daemon by gateway and migrate per-repository state |
| MPG-310R | #7623 | Research: Explain where each config value comes from |
| MPG-310 | #7662 | Explain where each config value comes from |
| MPG-311R | #7624 | Research: Target one project on a multi-project gateway |
| MPG-311 | #7663 | Target one project on a multi-project gateway |
| MPG-401 | #7595 | Design the allocation and scheduling policy |
| MPG-402R | #7625 | Research: Dispatch by cross-project priority within machine capacity |
| MPG-402 | #7668 | Dispatch by cross-project priority within machine capacity |
| MPG-403 | #7596 | Decide conflict ordering for shared intent |
| MPG-404R | #7626 | Research: Store shared intent changes with a local cache and outbox |
| MPG-404 | #7636 | Store shared intent changes with a local cache and outbox |
| MPG-405R | #7627 | Research: Reconcile shared intent deterministically |
| MPG-405 | #7646 | Reconcile shared intent deterministically |
| MPG-406R | #7628 | Research: Deliver gateway pause and pause-all durably |
| MPG-406 | #7654 | Deliver gateway pause and pause-all durably |
| MPG-407R | #7597 | Research: Publish full gateway workload in heartbeats |
| MPG-407 | #7637 | Publish full gateway workload in heartbeats |
| MPG-408R | #7598 | Research: Alert once when a gateway goes offline |
| MPG-408 | #7647 | Alert once when a gateway goes offline |
| MPG-501R | #7599 | Research: Delegate a ticket to another gateway through ownership |
| MPG-501 | #7664 | Delegate a ticket to another gateway through ownership |
| MPG-502R | #7600 | Research: Route Executor wakes by gateway and let one Executor claim a Decision |
| MPG-502 | #7638 | Route Executor wakes by gateway and let one Executor claim a Decision |
| MPG-601 | #7601 | Design the project-first dashboard and its browser sign-in |
| MPG-602R | #7629 | Research: Serve a gateway summary API the dashboard can read cross-origin |
| MPG-602 | #7648 | Serve a gateway summary API the dashboard can read cross-origin |
| MPG-603R | #7630 | Research: Show every project on one home screen |
| MPG-603 | #7655 | Show every project on one home screen |
| MPG-604R | #7631 | Research: Add gateway views and pause controls |
| MPG-604 | #7665 | Add gateway views and pause controls |
| MPG-701R | #7602 | Research: Prove the multi-project, multi-gateway MVP live |
| MPG-701 | #7669 | Prove the multi-project, multi-gateway MVP live |
