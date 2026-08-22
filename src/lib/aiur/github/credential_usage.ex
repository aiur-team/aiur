defmodule Aiur.GitHub.CredentialUsage do
  @moduledoc """
  The cross-credential view both `aiur github-usage` and `aiur github-cost` read.

  Two different numbers live here and they are never added together:

    * **admissions** — the broker's per-actor request counts, per `token_key`.
      These count requests Aiur admitted. They are ours, they are complete for
      this host, and they are safe to sum across credentials.
    * **window** — GitHub's own `x-ratelimit-*` figures for that credential.
      These are authoritative for *that credential's* budget and are observed
      only as a byproduct of calling it. A credential the daemon has not called
      this window has no window, which is reported as `nil`, never as zero.

  `github_cost_cli.ex` warns that a breakdown which does not add up to the
  credential's own `used` figure is a guess with a table around it. Pooling
  makes that worse, not better: the attributed points span every credential
  while an observed window covers one, so a pool total is only comparable to
  attribution when *every* credential in the pool has been observed. `pool/1`
  therefore reports `observed_credentials` against `configured_credentials` and
  marks the total `complete?` only when they match — a partial pool total is a
  floor, and a delta measured against a floor is not evidence.
  """

  alias Aiur.GitHub.{Budget, CredentialSelector}

  @resources ["core", "graphql"]

  @doc """
  One row per configured credential: identity, admissions, and observed window.

  `:usage_fun` and `:windows` are the seams; the defaults read the live broker
  and the live headroom table.
  """
  @spec rows(keyword()) :: [map()]
  def rows(opts \\ []) do
    actors = actors(opts)

    opts
    |> CredentialSelector.headroom()
    |> Enum.map(&row(&1, actors))
  end

  @doc """
  The pooled totals across every credential, per resource.

  `remaining` is the sum of observed remaining budget. It is a ceiling on what
  the pool can still spend, not a promise: the credentials' windows reset at
  different moments, so the pool never actually holds the sum at one instant.
  """
  @spec pool(keyword()) :: %{optional(String.t()) => map()}
  def pool(opts \\ []) do
    rows = Keyword.get_lazy(opts, :rows, fn -> rows(opts) end)
    configured = length(rows)

    Map.new(@resources, fn resource ->
      observed = rows |> Enum.map(&get_in(&1, [:windows, resource])) |> Enum.reject(&is_nil/1)

      {resource,
       %{
         configured_credentials: configured,
         observed_credentials: length(observed),
         complete?: configured > 0 and length(observed) == configured,
         limit: sum(observed, :limit),
         used: sum(observed, :used),
         remaining: sum(observed, :remaining),
         admissions: rows |> Enum.map(&get_in(&1, [:admissions, resource, :used])) |> Enum.reject(&is_nil/1) |> Enum.sum()
       }}
    end)
  end

  defp row(headroom, actors) do
    on_credential = Enum.filter(actors, &(&1.token_key == headroom.token_key and headroom.token_key != nil))

    headroom
    |> Map.put(:admissions, Map.new(@resources, &{&1, admissions(on_credential, &1)}))
    |> Map.put(:actors, Enum.map(on_credential, &actor_label/1))
    |> Map.update!(:windows, &Map.new(@resources, fn resource -> {resource, Map.get(&1, resource)} end))
  end

  # Ceilings are per actor, so the pooled ceiling for a credential is the sum of
  # the ceilings of the actors seen on it. `0` means "no ceiling" per actor, and
  # a single uncapped actor makes the credential's total uncapped rather than
  # smaller — summing a 0 into it would understate the ceiling.
  defp admissions(actors, resource) do
    figures = Enum.map(actors, &Map.get(&1, String.to_existing_atom(resource), %{}))
    limits = Enum.map(figures, &Map.get(&1, :limit, 0))

    %{
      used: figures |> Enum.map(&Map.get(&1, :used, 0)) |> Enum.sum(),
      limit: if(Enum.any?(limits, &(&1 == 0)), do: 0, else: Enum.sum(limits)),
      actors: length(actors)
    }
  end

  defp actor_label(actor) do
    case Map.get(actor, :consumer_label) do
      label when is_binary(label) and label != "" -> label
      _missing -> Map.get(actor, :consumer_key, "unknown")
    end
  end

  defp actors(opts) do
    usage_fun = Keyword.get(opts, :usage_fun, fn -> Budget.usage() end)

    case usage_fun.() do
      %{actors: actors} when is_list(actors) -> actors
      _unavailable -> []
    end
  end

  defp sum([], _field), do: nil
  defp sum(windows, field), do: windows |> Enum.map(&Map.get(&1, field, 0)) |> Enum.sum()
end
