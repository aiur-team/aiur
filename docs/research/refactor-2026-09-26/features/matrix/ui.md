# Ui feature use

Frozen-source use observations and working decisions. `none-found` means no use in the sampled evidence, not no users. Follow the feature ID in [features.json](../features.json) for the full evidence, caveats, exact challenge text and module list.

| ID | Feature | Observed use | Raw → working decision | Skeptical status |
| --- | --- | --- | --- | --- |
| ui-01 | Dashboard HTTP server, router and page shell | heavy | simplify → simplify | not challenged |
| ui-02 | Dashboard authentication and write gates (FinancialData access layer) | heavy | simplify → simplify | not challenged |
| ui-03 | Units page (fleet table, tickets panel, unit controls) | heavy | simplify → simplify | not challenged |
| ui-04 | Provider and usage meters on the Units page | regular | simplify → simplify | not challenged |
| ui-05 | Commands page (decision inbox, detail, answer, revise) | regular | keep → keep | not challenged |
| ui-06 | Agent conversation drawer and LiveConversation projection | occasional | merge → keep | overturned / narrowed |
| ui-07 | Dashboard voice: browser dictation and spoken replies | none-found | cut → keep | overturned / narrowed |
| ui-08 | ElevenLabs realtime speech-to-text client | rare | cut → keep | overturned / narrowed |
| ui-09 | ElevenLabs credit-quota meter | rare | cut → simplify | overturned / narrowed |
| ui-10 | Analytics page | regular | simplify → simplify | not challenged |
| ui-11 | Build Order pages (catalog and root detail) | heavy | simplify → simplify | not challenged |
| ui-12 | Build Order PlanningSource (pre-ticket demo data source) | none-found | cut → cut | holds |
| ui-13 | GitHub cache inspector page | occasional | cut → keep | overturned / narrowed; 0.0.6 cut pending PR #2841 |
| ui-14 | Stream Deck browser emulator page | none-found | cut → keep | overturned / narrowed |
| ui-15 | Stream Deck server channel and projections | regular | externalize → keep | overturned / narrowed |
| ui-16 | Stream Deck + physical sidecar (packages/streamdeck) | occasional | externalize → keep | overturned / narrowed |
| ui-17 | Stream Deck voice input and microphone settings | rare | cut → keep | overturned / narrowed |
| ui-18 | Stream Deck on-device Command answering | rare | cut → keep | overturned / narrowed |
| ui-19 | Stream Deck demo mode | rare | cut → cut | holds |
| ui-20 | TUI agent-list board | occasional | simplify → simplify | not challenged |
| ui-21 | TUI pane manager and conversation panes | occasional | simplify → simplify | not challenged |
| ui-22 | tmux integration, isolated tmux config and Ctrl-key bridges | regular | simplify → simplify | not challenged |
| ui-23 | opencode chat-pane renderer (slots, attach pool, SQLite injection, chat-completions bridge) | occasional | simplify → simplify | not challenged |
| ui-24 | Alert sounds | none-found | cut → keep | overturned / narrowed |
| ui-25 | Dashboard JSON observability API | rare | simplify → simplify | not challenged |
| ui-26 | Offline telemetry HTML report (mix aiur.telemetry.dashboard) | none-found | cut → cut | holds |
| ui-27 | Browser test harness and dashboard visual check | regular | keep → keep | not challenged |
| ui-28 | Dashboard stylesheet (dashboard.css) | heavy | simplify → simplify | not challenged |
| ui-29 | Unreferenced dashboard components | none-found | cut → cut | holds |
| ui-30 | Build Order graph layout engine (ELK worker + DOM-SVG adapter) - dead | none-found | cut → cut | holds |
| ui-31 | Remote Control affordances in the TUI | none-found | cut → keep | overturned / narrowed |
| ui-32 | UI launch switches (foreground attach, --bg, --bg --interactive, --no-dashboard, --host, --debug) | heavy | simplify → simplify | not challenged |
| ui-33 | Debug chat-pane ANSI recorder (documented, not implemented) | none-found | cut → cut | holds |
