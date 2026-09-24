defmodule Aiur.CodingAgent.ModelLabel do
  @moduledoc """
  Resolves the spec of a `model:<spec>` ticket label to what it selects.

  The order is fixed: a backend name (`claude`), then a non-selecting flag
  (`remote`, an effort such as `high`), then a backend-prefixed model
  (`codex-astra`), then a bare model or family name (`astra`, `opus`).

  A backend-prefixed label always selects its backend and passes its variant
  through, exactly as before — so version labels already in repos keep pinning.
  A bare name is matched against each backend's catalogue (the curated
  registry list plus whatever the installed CLI reported), so a model released
  after this build of aiur resolves without an upgrade. Backends that share one
  catalogue (`claude-repl` reads `claude`'s) count once and resolve to the
  catalogue's own backend.

  Pure: the caller supplies the catalogue reader, so the orchestrator can
  resolve from the cache alone and the agent runner can resolve again after a
  refresh, both through this one function.
  """

  alias Aiur.CodingAgent.Models

  @type backend :: String.t()
  @type provenance :: :discovered | :curated_only
  @type reader :: (backend() -> {[String.t()], provenance()})
  @type cause :: :unknown_name | :ambiguous | :catalog_unavailable
  @type result ::
          {:backend, backend()}
          | {:model, backend(), String.t()}
          | :not_a_selector
          | {:unresolved, cause(), [backend()]}

  @doc """
  Resolves `spec` against the `dispatchable` backends.

  Options: `:flags` (specs that are flags, not selectors — `remote` and the
  effort values), `:registered` (every registered backend, enabled or not),
  `:source_for` (backend -> the backend whose catalogue it reads), and
  `:catalogue` (the reader).
  """
  @spec resolve(String.t(), [backend()], keyword()) :: result()
  def resolve(spec, dispatchable, opts) when is_binary(spec) do
    flags = Keyword.get(opts, :flags, [])

    registered = Keyword.get(opts, :registered, dispatchable)

    cond do
      spec in dispatchable -> {:backend, spec}
      flag?(spec, flags) -> :not_a_selector
      prefixed = prefixed(spec, dispatchable) -> prefixed
      names_backend?(spec, registered) -> :not_a_selector
      true -> bare(spec, dispatchable, opts)
    end
  end

  # A backend that is registered but not enabled here (`model:deepseek` with
  # DeepSeek off) selects nothing. It must not be re-read as a model name —
  # an aggregator lists a `deepseek` family, and routing a ticket there would
  # contradict the operator leaving DeepSeek disabled.
  defp names_backend?(spec, registered), do: Enum.any?(registered, &(spec == &1 or String.starts_with?(spec, &1 <> "-")))

  # A flag also covers its prefixed form (`remote-opus` is the remote flag
  # carrying a variant), matching the pre-existing alias rule.
  defp flag?(spec, flags), do: Enum.any?(flags, &(spec == &1 or String.starts_with?(spec, &1 <> "-")))

  # Longest backend first, so `claude-repl-opus` is claude-repl + opus rather
  # than claude + `repl-opus`.
  defp prefixed(spec, dispatchable) do
    dispatchable
    |> Enum.sort_by(&(-String.length(&1)))
    |> Enum.find_value(fn backend ->
      if String.starts_with?(spec, backend <> "-"),
        do: {:model, backend, String.replace_prefix(spec, backend <> "-", "")}
    end)
  end

  defp bare(spec, dispatchable, opts) do
    source_for = Keyword.get(opts, :source_for, & &1)
    reader = Keyword.fetch!(opts, :catalogue)

    sources =
      dispatchable
      |> Enum.group_by(source_for)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {source, members} ->
        chosen = if source in members, do: source, else: hd(members)
        {chosen, reader.(chosen)}
      end)

    case Enum.filter(sources, fn {_source, {ids, _provenance}} -> offers?(ids, spec) end) do
      [{source, _catalogue}] -> {:model, source, spec}
      [_, _ | _] = matched -> {:unresolved, :ambiguous, Enum.map(matched, &elem(&1, 0))}
      [] -> unmatched(sources)
    end
  end

  defp offers?(ids, spec), do: spec in ids or Enum.any?(ids, &(Models.family(&1) == spec))

  # Nothing matched. If some catalogue was never discovered, the name may be
  # too new for the curated list alone — say so rather than calling it a typo.
  defp unmatched(sources) do
    case for({source, {_ids, :curated_only}} <- sources, do: source) do
      [] -> {:unresolved, :unknown_name, []}
      curated_only -> {:unresolved, :catalog_unavailable, curated_only}
    end
  end
end
