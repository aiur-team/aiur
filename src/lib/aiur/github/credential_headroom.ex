defmodule Aiur.GitHub.CredentialHeadroom do
  @moduledoc """
  Observed GitHub rate-limit windows, kept *per credential*.

  `Aiur.GitHub.Quota` already reads `x-ratelimit-*` off every response, but it
  keeps one window per resource because it was written when there was one
  credential; folding a second credential's headers into the same slot would
  make the meter oscillate between two accounts and mean nothing. This module
  keeps the same headers keyed by the broker's one-way token key, so
  `core` and `graphql` headroom can be compared across credentials.

  It is a plain ETS-backed GenServer with no polling of its own. Every figure
  here is a byproduct of a request the daemon was already making — asking GitHub
  for headroom would itself cost headroom, which is the failure this whole
  change exists to avoid. A credential the daemon has not called yet therefore
  has *no* observation, and the selector treats that as "probably full" rather
  than as zero: an unused credential is exactly the one worth trying.

  Windows are only trusted while their `reset_at` is in the future. GitHub's
  hourly window rolls, so a stale `remaining: 0` from the previous hour must not
  keep a credential benched forever.
  """

  use GenServer

  alias Aiur.Alerts
  alias Aiur.GitHub.{Budget, Transport}

  @table __MODULE__
  @disagreements_table Module.concat(__MODULE__, Disagreements)
  @resources ["core", "graphql"]

  @type window :: %{
          limit: non_neg_integer(),
          remaining: non_neg_integer(),
          used: non_neg_integer(),
          reset_at: DateTime.t(),
          observed_at: DateTime.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Records the rate-limit headers of a completed request against its credential.

  Never raises and never blocks the caller: this runs on the GitHub request path
  and an accounting problem must not become a request failure.
  """
  @spec observe(map(), {:ok, map()} | {:error, term()}) :: :ok
  def observe(request, result) do
    with %{token: token} <- request,
         key when is_binary(key) <- Budget.token_key(token),
         {:ok, %{headers: headers}} <- result,
         %{} = window <- window_from(headers) do
      put(key, resource(headers, request), window)
    else
      _nothing -> :ok
    end
  rescue
    _error -> :ok
  catch
    # The docstring above promises this never takes the request down. That
    # promise has to cover exits as well as raises, or it is only true of the
    # failures that happen to be raises today.
    :exit, _reason -> :ok
  end

  @doc """
  Observed windows as `%{token_key => %{resource => window}}`.

  Expired windows are dropped on read, so a caller never has to know the rolling
  window's phase to interpret the result.
  """
  @spec snapshot(DateTime.t()) :: %{optional(String.t()) => %{optional(String.t()) => window()}}
  def snapshot(now \\ DateTime.utc_now()) do
    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {_key, window} -> fresh?(window, now) end)
    |> Enum.group_by(fn {{token_key, _resource}, _window} -> token_key end, fn {{_token_key, resource}, window} ->
      {resource, window}
    end)
    |> Map.new(fn {token_key, entries} -> {token_key, Map.new(entries)} end)
  rescue
    ArgumentError -> %{}
  end

  @doc """
  The observed window for one credential and resource, or `nil` when the
  credential has not been observed inside the current window.
  """
  @spec window(String.t() | nil, String.t(), DateTime.t()) :: window() | nil
  def window(token_key, resource, now \\ DateTime.utc_now())

  def window(token_key, resource, now) when is_binary(token_key) do
    case :ets.lookup(@table, {token_key, resource}) do
      [{_key, window}] -> if fresh?(window, now), do: window
      _absent -> nil
    end
  rescue
    ArgumentError -> nil
  end

  def window(_token_key, _resource, _now), do: nil

  @doc "The resources this module meters."
  @spec resources() :: [String.t()]
  def resources, do: @resources

  @doc "Discards every observation. Test support."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@disagreements_table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    # `:public` because `observe/2` runs on whichever process made the request;
    # routing every observation through this GenServer would put a serialization
    # point on the GitHub request path for a write nobody reads synchronously.
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    :ets.new(@disagreements_table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, %{}}
  end

  @doc "Alerts once per credential/resource/reset window when local billed usage contradicts GitHub."
  @spec reconcile_budget_meter(String.t(), String.t(), map(), map(), keyword()) :: :ok
  def reconcile_budget_meter(token_key, resource, local, window, opts \\ [])

  def reconcile_budget_meter(token_key, resource, local, %{limit: limit, used: github_used, reset_at: reset_at}, opts)
      when is_binary(token_key) and is_binary(resource) and is_integer(limit) and limit > 0 and is_integer(github_used) do
    local_used = Map.get(local, :used, 0)
    local_limit = Map.get(local, :limit, 0)
    margin = margin(limit)

    message =
      "GitHub local budget meter disagrees with the credential window for #{resource}: " <>
        "local billed=#{local_used}/#{local_limit}, GitHub used=#{github_used}/#{limit}, " <>
        "margin=#{margin}, reset_at=#{DateTime.to_iso8601(reset_at)}, credential=#{credential_hint(token_key)}."

    signal({token_key, resource, :actor}, local_used - github_used > margin, reset_at, message, opts)
  rescue
    _unavailable -> :ok
  catch
    :exit, _reason -> :ok
  end

  def reconcile_budget_meter(_token_key, _resource, _local, _window, _opts), do: :ok

  @doc """
  Alerts when a shared (cooldown/pacing) hold outlives the credential's own window.

  A shared hold is not an hourly ledger — it is the token-wide cooldown the
  broker sets from a rate-limit response. That cooldown can survive the window
  that justified it, which is the case where the guard stops the fleet while
  GitHub still reports almost the whole credential unspent.
  """
  @spec reconcile_shared_hold(String.t(), String.t(), map(), keyword()) :: :ok
  def reconcile_shared_hold(token_key, resource, window, opts \\ [])

  def reconcile_shared_hold(token_key, resource, %{limit: limit, remaining: remaining, reset_at: reset_at}, opts)
      when is_binary(token_key) and is_binary(resource) and is_integer(limit) and limit > 0 and is_integer(remaining) do
    margin = margin(limit)

    message =
      "GitHub shared budget hold contradicts the credential window for #{resource}: " <>
        "the local guard is holding every #{resource} request while GitHub reports " <>
        "remaining=#{remaining}/#{limit} (margin=#{margin}), " <>
        "reset_at=#{DateTime.to_iso8601(reset_at)}, credential=#{credential_hint(token_key)}."

    signal({token_key, resource, :shared}, remaining > margin, reset_at, message, opts)
  rescue
    _unavailable -> :ok
  catch
    :exit, _reason -> :ok
  end

  def reconcile_shared_hold(_token_key, _resource, _window, _opts), do: :ok

  defp margin(limit), do: max(1, ceil(limit * 0.05))

  defp credential_hint(token_key), do: binary_part(token_key, 0, min(12, byte_size(token_key)))

  # One alert per key per reset window, cleared as soon as the meters agree
  # again so the next real divergence still speaks.
  defp signal(key, disagrees?, reset_at, message, opts) do
    if disagrees? do
      if activate_disagreement(key, DateTime.to_unix(reset_at)) do
        alert_fun = Keyword.get(opts, :alert_fun, &Alerts.emit_system/2)

        case alert_fun.("system.github.budget_meter_disagreement",
               reason: message,
               needs_attention: true,
               severity: "warning"
             ) do
          :ok -> :ok
          _failed -> :ets.delete(@disagreements_table, key)
        end
      end
    else
      :ets.delete(@disagreements_table, key)
    end

    :ok
  end

  defp activate_disagreement(key, signature) do
    case :ets.lookup(@disagreements_table, key) do
      [{^key, ^signature}] -> false
      _previous -> :ets.insert(@disagreements_table, {key, signature})
    end
  end

  defp put(key, resource, window) when resource in @resources do
    :ets.insert(@table, {{key, resource}, window})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp put(_key, _resource, _window), do: :ok

  defp fresh?(%{reset_at: reset_at}, now), do: DateTime.compare(reset_at, now) == :gt
  defp fresh?(_window, _now), do: false

  defp resource(headers, request) do
    case Transport.header(headers, "x-ratelimit-resource") do
      resource when resource in @resources -> resource
      _other -> Budget.request_resource(request)
    end
  end

  defp window_from(headers) do
    with limit when is_integer(limit) and limit > 0 <- integer_header(headers, "x-ratelimit-limit"),
         remaining when is_integer(remaining) <- integer_header(headers, "x-ratelimit-remaining"),
         reset when is_integer(reset) <- integer_header(headers, "x-ratelimit-reset") do
      %{
        limit: limit,
        remaining: max(remaining, 0),
        used: max(limit - remaining, 0),
        reset_at: DateTime.from_unix!(reset),
        observed_at: DateTime.utc_now()
      }
    else
      _incomplete -> nil
    end
  end

  defp integer_header(headers, name) do
    case Transport.header(headers, name) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, _rest} -> integer
          :error -> nil
        end

      _missing ->
        nil
    end
  end
end
