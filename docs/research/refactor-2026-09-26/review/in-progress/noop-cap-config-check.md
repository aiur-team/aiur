# `platform-misc-01`: noop-turn cap configuration

Snapshot: `3339b887196d5e9aefb273117a14bf33391ee41f`.

The source-level claim holds. `Aiur.Config.Schema.Agent` declares `max_consecutive_noop_turns` with default 3 (`agent.ex:191`), but its explicit `cast/3` permitted list at `agent.ex:280-324` omits that field. Ecto changesets discard unpermitted attributes, so a supplied value cannot reach the parsed struct through that path. `Aiur.Config.agent_max_consecutive_noop_turns/0` subsequently reads the struct field (`config.ex:898-904`), making the default appear authoritative even when an operator supplied a value. The raw finding's quoted behavior is therefore supported by the source chain.

This is a silent configuration defect with possible repeated agent recycling, but the raw P0 severity is not supported by an observed production incident or measured affected population. Provisional severity is P1 pending a separate interpretation check. This source trace is not a full config-parse execution or one of the required independent skeptic verdicts.
