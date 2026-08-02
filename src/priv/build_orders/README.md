# Build Order packs

JSON packs are the state-node membership and provenance source for the Build
Order dashboard. When a running state node has `build-order.json` packs,
`AiurWeb.BuildOrder.PlanningSource` is selected automatically. The GitHub graph
projection remains the fallback when no state-node pack exists.

For an explicit local pack (including a pre-ticket preview), configure:

`config :aiur, :build_order_planning_pack, "priv/build_orders/<file>.json"`

## Pack format

```jsonc
{
  "build_order_id": "owner/repo:slug",
  "title": "Human title",
  "repository": "owner/repo",
  "workstreams": [{ "id": "core", "title": "Core" }],
  "tickets": [
    {
      "id": "CT-101",              // ticket id (numeric portion becomes the display id)
      "title": "…",
      "lane": "core",             // epic / workstream (column)
      "phase": 1,                  // execution wave (row)
      "complexity": 3,             // 1..5 (optional)
      "depends_on": ["CT-100"],   // dependency edges
      "ticket": 1234,             // null before materialization
      "doc": "tickets/CT-101.md",
      "provenance": "planned"     // optional; omitted also means planned
    }
  ]
}
```

To add a ticket after a build begins, append it to exactly one pack's
`tickets[]` with `"provenance": "discovered"` and an ISO-8601
`"added_at"` value. It remains in its declared lane and phase, participates
in its `depends_on` edges and current progress denominator, and is visually
marked inline. No repository-wide label is involved.

## croptracker-demo.json (deletable demo data)

Generated from the sibling `../croptracker` repo's pre-ticket planning pack
(`docs/build-order/build-order-phase-{1..9}.json` — the machine-readable phase
membership, labels, and cross-phase edges — plus each ticket's markdown header
for its title). This tracks plan v2: 116 tickets across 9 phases and 6 lanes.
It may be removed without changing the pack-backed runtime source.
