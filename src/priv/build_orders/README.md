# Planning packs (pre-ticket Build Orders)

The Build Order dashboard reads materialized JSON packs through
`AiurWeb.BuildOrder.PlanningSource`. It discovers fresh publisher workspace
mirrors before repository state-node manifests, and includes pre-ticket packs
and roots whose GitHub labels have not caught up. Repositories with no
materialized packs continue to use the live GitHub catalog.

For a focused demo or test, override the discovered catalog with
`config :aiur, :build_order_planning_pack, "priv/build_orders/<file>.json"`.
Normal catalogs discover every pack for the daemon's tracked repository.

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
      "document_url": "https://…", // planning doc link (optional)
      "github": null               // filled once materialized
    }
  ]
}
```

## croptracker-demo.json (deletable demo data)

Generated from the sibling `../croptracker` repo's pre-ticket planning pack
(`docs/build-order/build-order-phase-{1..9}.json` — the machine-readable phase
membership, labels, and cross-phase edges — plus each ticket's markdown header
for its title). This tracks plan v2: 116 tickets across 9 phases and 6 lanes.
To delete the demo: remove this file. `PlanningSource` will continue to
discover the remaining materialized packs.
