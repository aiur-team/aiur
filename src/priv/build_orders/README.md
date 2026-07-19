# Planning packs (pre-ticket Build Orders)

JSON packs in this directory can be rendered in the Build Order spatial
dashboard **before any GitHub issue exists**, via
`AiurWeb.BuildOrder.PlanningSource`.

Enable at build time and point the dashboard at a pack:

```
AIUR_BUILD_ORDER_DEMO=1 aiurdev --bg --debug
```

That sets `config :aiur, :build_order_data_source, AiurWeb.BuildOrder.PlanningSource`
(see `config/config.exs`). Override the pack with
`config :aiur, :build_order_planning_pack, "priv/build_orders/<file>.json"`
(defaults to `croptracker-demo.json`).

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
(`docs/build-order/build-order-phase-{1..4}.json` + ticket markdown) — the first
100 of 115 tickets (Aiur caps a root at 100 direct members). To delete the demo:
remove this file and the `AIUR_BUILD_ORDER_DEMO` block in `config/config.exs`.
`PlanningSource` itself is a general feature and can stay.
