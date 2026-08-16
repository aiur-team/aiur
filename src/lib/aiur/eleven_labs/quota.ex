defmodule Aiur.ElevenLabs.Quota do
  @moduledoc """
  Fleet-wide view of the ElevenLabs account credit quota.

  `GET /v1/user/subscription` reports a *character/credit* quota
  (`character_count`, `character_limit`, `next_character_count_reset_unix`,
  `tier`). It reports no dollar balance: the only money-shaped fields it carries
  are amounts owed (`current_overage`, `open_invoices`), never a remaining one.
  So this authority publishes the credit quota and nothing that could be read as
  a spendable balance.

  The quota is also not a voice-input spend meter. Speech-to-text — what Stream
  Deck voice input actually uses — is billed per minute of audio, while the
  character quota is primarily the text-to-speech credit pool. The surface that
  renders this snapshot names it for what it measures, the account credit quota.

  Three standings are distinct, and collapsing any pair of them would lie to the
  operator:

    * `:unconfigured` — no API key is configured. Aiur has no account to meter,
      so the meter is absent rather than reporting a zero or an error.
    * `:unknown` — a key is configured and no answer has arrived yet.
    * `:failed` — a configured key's request failed. That is a real fault worth
      surfacing, and it carries the reason (`:authentication`, `:rate_limited`,
      `:provider_error`, `:transport`, `:malformed`, `:probe_failed`).

  Resolving the key is therefore separated from performing the request, so a
  raise while reading configuration degrades to "no key configured" instead of
  being reported as a failed provider.

  The API key is a secret. It travels in a request header, is never placed in a
  URL, and is never logged, attached to a failure reason, or held in the
  snapshot.
  """

  use GenServer

  alias Aiur.Config

  @endpoint "https://api.elevenlabs.io/v1/user/subscription"

  # The credit quota moves with agent-scale usage, not per request, and the
  # account endpoint is a whole-account read. Five minutes keeps the card current
  # without spending an account call per dashboard tick.
  @refresh_interval_ms 300_000
  @request_timeout_ms 15_000

  @unconfigured %{state: :unconfigured, window: nil, failure: nil, observed_at: nil}

  @type observation :: :unconfigured | {:ok, map()} | {:error, atom()}
  @type snapshot :: %{
          state: :unconfigured | :unknown | :observed | :failed,
          window: map() | nil,
          failure: atom() | nil,
          observed_at: DateTime.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Ingest one observation. `:unconfigured` clears the account; `{:ok, response}`
  is an HTTP answer to parse; `{:error, reason}` is a named failure.
  """
  @spec observe(GenServer.server(), observation()) :: :ok
  def observe(server \\ __MODULE__, observation) do
    GenServer.cast(server, {:observe, observation})
  catch
    :exit, _reason -> :ok
  end

  @doc """
  The current standing. An absent authority reports `:unconfigured` — the meter
  disappears rather than inventing a failure for a process that is simply not
  running.
  """
  @spec snapshot(GenServer.server()) :: snapshot()
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  catch
    :exit, _reason -> @unconfigured
  end

  @impl true
  def init(opts) do
    refresh? = Keyword.get(opts, :refresh?, Application.get_env(:aiur, :elevenlabs_quota_refresh?, true))
    api_key_fun = Keyword.get(opts, :api_key_fun, &Config.elevenlabs_api_key/0)

    state = %{
      state: initial_state(api_key_fun),
      window: nil,
      failure: nil,
      observed_at: nil,
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      api_key_fun: api_key_fun,
      request_fun: Keyword.get(opts, :request_fun, &default_request/1),
      refresh_interval_ms: Keyword.get(opts, :refresh_interval_ms, @refresh_interval_ms),
      refresh_ref: nil
    }

    if refresh?, do: Process.send_after(self(), :refresh, 0)
    {:ok, state}
  end

  @impl true
  def handle_cast({:observe, observation}, state), do: {:noreply, ingest(state, observation)}

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, Map.take(state, [:state, :window, :failure, :observed_at]), state}
  end

  # The request runs off the authority's own process so a slow or hung endpoint
  # can never block a `snapshot/1` call the dashboard makes on every tick.
  @impl true
  def handle_info(:refresh, %{refresh_ref: nil} = state) do
    server = self()
    api_key_fun = state.api_key_fun
    request_fun = state.request_fun

    {_pid, ref} = spawn_monitor(fn -> observe(server, fetch(api_key_fun, request_fun)) end)
    {:noreply, %{state | refresh_ref: ref}}
  end

  def handle_info(:refresh, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{refresh_ref: ref} = state) do
    Process.send_after(self(), :refresh, state.refresh_interval_ms)
    {:noreply, %{state | refresh_ref: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  Resolve the credential and read the account, returning the observation to
  ingest. Public so a refresh can be driven deterministically.
  """
  @spec fetch((-> String.t() | nil), (String.t() -> {:ok, map()} | {:error, atom()})) :: observation()
  def fetch(api_key_fun, request_fun) do
    case api_key(api_key_fun) do
      :none -> :unconfigured
      {:ok, api_key} -> request(request_fun, api_key)
    end
  end

  # "No key" and "the read failed" are different standings, so the credential
  # lookup has its own rescue and degrades to `:none`. A blanket rescue around
  # both would report an unreadable config as a failed ElevenLabs account and
  # render a meter for a provider the operator never configured.
  defp api_key(api_key_fun) do
    case api_key_fun.() do
      key when is_binary(key) and key != "" -> {:ok, key}
      _absent -> :none
    end
  rescue
    _unavailable -> :none
  catch
    _kind, _reason -> :none
  end

  # The raised value is deliberately discarded rather than logged or attached to
  # the reason: it can carry the request that raised, and the request carries the
  # API key.
  defp request(request_fun, api_key) do
    request_fun.(api_key)
  rescue
    _error -> {:error, :probe_failed}
  catch
    _kind, _reason -> {:error, :probe_failed}
  end

  defp default_request(api_key) do
    case Req.get(@endpoint, headers: [{"xi-api-key", api_key}], receive_timeout: @request_timeout_ms, retry: false) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, _reason} -> {:error, :transport}
    end
  end

  defp initial_state(api_key_fun) do
    case api_key(api_key_fun) do
      :none -> :unconfigured
      {:ok, _api_key} -> :unknown
    end
  end

  defp ingest(state, :unconfigured), do: %{state | state: :unconfigured, window: nil, failure: nil, observed_at: nil}

  defp ingest(state, {:ok, response}) do
    now = state.clock.()

    with :ok <- response_status(response),
         {:ok, window} <- subscription_window(Map.get(response, :body), now) do
      %{state | state: :observed, window: window, failure: nil, observed_at: now}
    else
      {:error, reason} -> failed(state, reason)
    end
  end

  defp ingest(state, {:error, reason}) when is_atom(reason), do: failed(state, reason)
  defp ingest(state, _observation), do: failed(state, :malformed)

  # A failed read drops the window rather than retaining it. The meter reads
  # *remaining*, so a retained figure presented beside a failure is the one value
  # an operator would act on while it is no longer known to be true.
  defp failed(state, reason), do: %{state | state: :failed, window: nil, failure: reason, observed_at: nil}

  defp response_status(%{status: status}) when status in 200..299, do: :ok
  defp response_status(%{status: 401}), do: {:error, :authentication}
  defp response_status(%{status: 403}), do: {:error, :authentication}
  defp response_status(%{status: 429}), do: {:error, :rate_limited}
  defp response_status(%{status: status}) when is_integer(status), do: {:error, :provider_error}
  defp response_status(_response), do: {:error, :malformed}

  defp subscription_window(body, now) when is_map(body) do
    with {:ok, limit} <- non_negative_integer(Map.get(body, "character_limit")),
         {:ok, used} <- non_negative_integer(Map.get(body, "character_count")) do
      remaining = max(limit - used, 0)

      {:ok,
       %{
         limit: limit,
         used: used,
         remaining: remaining,
         remaining_percent: remaining_percent(remaining, limit),
         tier: tier(Map.get(body, "tier")),
         reset_at: reset_at(Map.get(body, "next_character_count_reset_unix")),
         observed_at: now
       }}
    end
  end

  defp subscription_window(_body, _now), do: {:error, :malformed}

  # Percentage *remaining*, clamped to 0..100.
  #
  # A zero (or absent) limit is not a meter: there is no denominator, so the
  # window reports no percentage at all rather than dividing by zero or
  # inventing a full or empty bar.
  #
  # The clamp bounds are floats on purpose. `max/2` and `min/2` hand back
  # whichever argument wins, so an integer bound would be returned as an integer
  # the moment the clamp engages — and `Float.round/2` has no integer clause, so
  # it raises. That is the DeepSeek `balance_used_percent` fault, and this is the
  # same guard against it.
  defp remaining_percent(_remaining, limit) when limit <= 0, do: nil

  defp remaining_percent(remaining, limit) do
    (remaining / limit * 100)
    |> max(0.0)
    |> min(100.0)
    |> Float.round(1)
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp non_negative_integer(_value), do: {:error, :malformed}

  defp tier(tier) when is_binary(tier) and tier != "", do: tier
  defp tier(_tier), do: nil

  defp reset_at(unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, reset_at} -> reset_at
      {:error, _reason} -> nil
    end
  end

  defp reset_at(_unix), do: nil
end
