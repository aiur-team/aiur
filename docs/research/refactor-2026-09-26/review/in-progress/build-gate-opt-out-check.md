# `loose-4-01`: build-gate opt-out startup failure

Snapshot: `3339b887196d5e9aefb273117a14bf33391ee41f`.

The reproduction chain holds. `BuildGate.enabled?/1` returns false when slots and stagger are zero and no positive memory floor is set (`src/lib/aiur/build_gate.ex:120-127`), matching the documented explicit opt-out (`website/docs-app/reference/configuration.md:369`). `BuildGateHoldMonitor.init/1` returns `{:ignore, %State{}}` on that branch (`src/lib/aiur/build_gate_hold_monitor.ex:78-93`), and `Aiur` includes the monitor as an ordinary supervisor child (`src/lib/aiur.ex:313`). A minimal OTP GenServer with `init/1` returning `{:ignore, %{}}` exits with `bad return value`; `:ignore` must be a bare atom. Reproduction command, with the project's private OTP installed, was:

```sh
elixir -e 'defmodule BadInit do use GenServer; def init(_), do: {:ignore, %{}}; end; IO.inspect(GenServer.start_link(BadInit, []))'
```

Observed exit: `** (EXIT ...) bad return value: {:ignore, %{}}`. This tests the OTP contract, not a full Aiur boot under the opt-out config. The source chain is sufficient to establish that the documented opt-out can prevent startup. The raw P0 severity appears too broad for a nondefault, reversible configuration failure; provisional severity is P1 pending independent interpretation review. No live population or incident frequency was measured. Do not count this note as either of the two required independent skeptic verdicts.
