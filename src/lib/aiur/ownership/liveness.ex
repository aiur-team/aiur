defmodule Aiur.Ownership.Liveness do
  @moduledoc """
  Is the gateway that owns a ticket still alive? Answers `online`, `offline` or `unknown`.

  Only `offline` lets a transfer proceed without `--force`; `unknown` counts as live. Evidence, in order:
  self, a fresh store heartbeat for the owner's `gateway_id`, an answering hello, then a store row
  older than the threshold (`offline`). No row, a store error or no store is `unknown`, never `offline`.

  Heartbeats are matched by `gateway_id` only: roster rows carry no daemon key, so a live second
  daemon on the owner's machine keeps the owner `online` (errs toward refusing).
  """

  alias Aiur.Instance.Roster
  alias Aiur.Machine.Settings, as: MachineSettings

  @type status :: :online | :offline | :unknown
  @type result :: %{status: status(), source: atom() | nil, age_ms: non_neg_integer() | nil}
  @type evidence :: %{self?: boolean(), roster: term(), hello: :alive | :unreachable}

  @doc "Pure classification. `offline_after_ms` is compared with `>`: a row exactly that old is still online."
  @spec classify(map(), evidence(), non_neg_integer()) :: result()
  def classify(owner, evidence, offline_after_ms) do
    row_age = row_age(evidence.roster, owner.gateway_id)

    cond do
      evidence.self? -> result(:online, :self, nil)
      is_integer(row_age) and row_age <= offline_after_ms -> result(:online, :heartbeat, row_age)
      evidence.hello == :alive -> result(:online, :hello, row_age)
      is_integer(row_age) -> result(:offline, :heartbeat, row_age)
      true -> result(:unknown, nil, nil)
    end
  end

  @doc "Collects the evidence for `owner`. `opts`: `:roster_fun`, `:hello_fun` (arity 1), `:self_fun`."
  @spec gather(map(), keyword()) :: evidence()
  def gather(owner, opts \\ []) do
    roster = Keyword.get(opts, :roster_fun, &Roster.list/0).()
    # ponytail: hello (MPG-207) is not built; until a hello_fun is injected the owner never answers it.
    hello = Keyword.get(opts, :hello_fun, fn _ -> :unreachable end).(owner)
    self_fun = Keyword.get(opts, :self_fun, fn -> false end)
    %{self?: self_fun.(), roster: roster, hello: hello}
  end

  @doc "`coordination.offline_after_seconds` in milliseconds (default 180 s when settings are unreadable)."
  @spec offline_after_ms() :: pos_integer()
  def offline_after_ms do
    case MachineSettings.get() do
      {:ok, %{coordination: %{offline_after_seconds: s}}} when is_integer(s) -> s * 1000
      _ -> 180_000
    end
  end

  defp row_age({:ok, %{instances: rows}}, gateway_id) do
    case for(%{gateway_id: ^gateway_id, age_ms: age} <- rows, do: age) do
      [] -> nil
      ages -> Enum.min(ages)
    end
  end

  defp row_age(_roster, _gateway_id), do: nil

  defp result(status, source, age_ms), do: %{status: status, source: source, age_ms: age_ms}
end
