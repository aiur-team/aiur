defmodule Aiur.Claude.UsageApi do
  @moduledoc """
  Reads Claude quota utilization straight from the account usage endpoint.

  The agent event stream reports a standing and a reset time but never a
  consumed fraction, so a percentage cannot be derived from agent activity. The
  Claude Code TUI's `/usage` does not try: it calls `GET /api/oauth/usage` with
  the stored OAuth token. This reads the same endpoint.

  Doing it here rather than through the app-server adapter is deliberate. The
  reading is one authenticated HTTPS GET; routing it through a provider session
  would require a live agent, a turn, and a session-scoped account binding to
  deliver a number that depends on none of them. Reading it directly means the
  meters work on an idle daemon with no agents at all.

  The endpoint rate-limits, and a 429 yields no reading, so an eager caller ends
  up with strictly less data than a patient one. `Aiur.ProviderMeterRefresh`
  owns the cadence; this module performs one request per call and never retries
  on its own.
  """

  require Logger

  @usage_url "https://api.anthropic.com/api/oauth/usage"
  @oauth_beta "oauth-2025-04-20"
  @timeout_ms 8_000
  @cache_key {__MODULE__, :reading}
  @default_ttl_ms 300_000
  # A 429 means no reading at all; wait before asking again.
  @rate_limited_backoff_ms 5 * 60_000

  # Windows the endpoint reports, in the order an operator plans against. The
  # weekly windows come first because they are the ones that actually constrain
  # a day's work; the five-hour session window resets so often that it is a
  # poor planning signal on its own. Every reported window is carried through —
  # the presentation layer decides what to lead with, not this module.
  #
  # The list order is the window priority, so a window is selected by its
  # identifier and never by a rendered string.
  @window_specs [
    {"seven_day", "Weekly (all models)", :weekly},
    {"seven_day_opus", "Weekly (Opus)", :weekly},
    {"seven_day_sonnet", "Weekly (Sonnet)", :weekly},
    {"five_hour", "Session (5-hour)", :session}
  ]

  # A weekly window the endpoint did not report must still render, as words
  # saying it was not reported. Dropping it silently would leave the card
  # showing only the session bar, which reads as a healthy weekly standing that
  # was never actually observed.
  @required_windows ["seven_day"]

  @type window_reading :: %{
          window: String.t(),
          label: String.t(),
          scope: :weekly | :session,
          priority: non_neg_integer(),
          coverage: :supported | :empty_supported,
          used_percent: number() | nil,
          resets_at: DateTime.t() | nil
        }

  @type reading :: %{
          used_percent: number(),
          resets_at: DateTime.t() | nil,
          window: String.t(),
          windows: [window_reading()]
        }

  @doc """
  Fetch current utilization.

  Returns `{:error, reason}` rather than raising for every expected condition —
  no credentials file, an API-key account with no OAuth token, an expired
  token, a 429, or an offline machine. None of those should disturb a caller.
  """
  @spec fetch(keyword()) :: {:ok, reading()} | {:error, atom()}
  def fetch(opts \\ []) do
    now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))

    case cached(now_ms) do
      {:ok, _reading} = hit -> hit
      :miss -> fetch_and_cache(opts, now_ms)
    end
  end

  @doc "Drop the cached reading. For tests and for a forced refresh."
  @spec reset_cache() :: :ok
  def reset_cache, do: :persistent_term.erase(@cache_key) && :ok

  defp fetch_and_cache(opts, now_ms) do
    result =
      with {:ok, token} <- access_token(opts),
           {:ok, body} <- get_usage(token, opts) do
        select_window(body)
      end

    put_cache(result, now_ms, opts)
    result
  end

  # The endpoint is tight enough that two calls in quick succession earn a 429,
  # and a 429 yields no reading at all — so an eager caller ends up with
  # strictly less data than a patient one. Hold a successful reading for the
  # operator's configured cadence, and after a 429 keep serving the last good
  # value rather than asking again immediately.
  defp cached(now_ms) do
    case :persistent_term.get(@cache_key, nil) do
      %{reading: {:ok, _} = reading, fresh_until: until} when until > now_ms -> reading
      _stale_or_absent -> :miss
    end
  end

  defp put_cache({:ok, _reading} = result, now_ms, opts) do
    :persistent_term.put(@cache_key, %{reading: result, fresh_until: now_ms + ttl_ms(opts)})
  end

  defp put_cache({:error, :rate_limited}, now_ms, _opts) do
    # Keep any previous good reading, but stop asking for a while.
    previous = :persistent_term.get(@cache_key, %{})
    reading = Map.get(previous, :reading, {:error, :rate_limited})
    :persistent_term.put(@cache_key, %{reading: reading, fresh_until: now_ms + @rate_limited_backoff_ms})
  end

  defp put_cache(_error, _now_ms, _opts), do: :ok

  defp ttl_ms(opts) do
    case Keyword.get(opts, :ttl_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _unset -> configured_ttl_ms()
    end
  end

  defp configured_ttl_ms do
    case Aiur.Config.settings() do
      {:ok, %{polling: %{usage_interval_seconds: seconds}}} when is_integer(seconds) and seconds > 0 -> seconds * 1_000
      _unavailable -> @default_ttl_ms
    end
  rescue
    _error -> @default_ttl_ms
  catch
    _kind, _reason -> @default_ttl_ms
  end

  @doc "The stored Claude Code OAuth access token, when one is usable."
  @spec access_token(keyword()) :: {:ok, String.t()} | {:error, atom()}
  def access_token(opts \\ []) do
    path = Keyword.get(opts, :credentials_path, default_credentials_path())
    now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))

    with {:ok, raw} <- read_file(path),
         {:ok, json} <- decode(raw) do
      oauth_token(Map.get(json, "claudeAiOauth", %{}), now_ms)
    end
  end

  # An empty or absent `accessToken` is "not signed in", distinct from a token
  # that was present but has lapsed: the former needs a fresh Claude Code login,
  # the latter needs a token refresh. Both are definite errors — never a state
  # that hangs a surface in "loading".
  defp oauth_token(%{"accessToken" => token} = oauth, now_ms) when is_binary(token) and token != "" do
    if expired?(oauth, now_ms), do: {:error, :token_expired}, else: {:ok, token}
  end

  defp oauth_token(_oauth, _now_ms), do: {:error, :no_oauth_token}

  @doc false
  @spec default_credentials_path() :: Path.t()
  def default_credentials_path do
    Path.join([System.get_env("HOME") || Path.expand("~"), ".claude", ".credentials.json"])
  end

  # --- request -------------------------------------------------------------

  defp get_usage(token, opts) do
    case Keyword.get(opts, :request_fun, &default_request/1).(token) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: 429}} -> {:error, :rate_limited}
      {:ok, %{status: status}} -> {:error, http_reason(status)}
      {:error, _reason} -> {:error, :request_failed}
    end
  rescue
    _error -> {:error, :request_failed}
  catch
    _kind, _reason -> {:error, :request_failed}
  end

  defp default_request(token) do
    Req.get(@usage_url,
      headers: [
        {"authorization", "Bearer " <> token},
        {"accept", "application/json"},
        {"anthropic-beta", @oauth_beta}
      ],
      receive_timeout: @timeout_ms,
      retry: false
    )
  end

  defp http_reason(status) when status in [401, 403], do: :unauthorized
  defp http_reason(_status), do: :request_failed

  # --- parsing -------------------------------------------------------------

  @doc """
  Every window the body reports, in priority order, plus the worst-consumed one
  promoted to the top level for callers that want a single number.

  A required window the body omits is still returned, carrying
  `coverage: :empty_supported` and no percentage, so it can be rendered as
  "not reported" instead of vanishing.
  """
  @spec select_window(map()) :: {:ok, reading()} | {:error, :no_utilization}
  def select_window(body) when is_map(body) do
    windows =
      @window_specs
      |> Enum.with_index()
      |> Enum.flat_map(fn {{name, label, scope}, priority} ->
        window_reading(body, name, label, scope, priority)
      end)

    case Enum.filter(windows, &is_number(&1.used_percent)) do
      [] ->
        {:error, :no_utilization}

      observed ->
        worst = Enum.max_by(observed, & &1.used_percent)

        {:ok,
         %{
           used_percent: worst.used_percent,
           resets_at: worst.resets_at,
           window: worst.window,
           windows: windows
         }}
    end
  end

  def select_window(_body), do: {:error, :no_utilization}

  defp window_reading(body, name, label, scope, priority) do
    case Map.get(body, name) do
      %{"utilization" => percent} = window when is_number(percent) and percent >= 0 ->
        [
          %{
            window: name,
            label: label,
            scope: scope,
            priority: priority,
            coverage: :supported,
            used_percent: min(percent, 100),
            resets_at: parse_reset(Map.get(window, "resets_at"))
          }
        ]

      _absent_or_unusable ->
        if name in @required_windows do
          [
            %{
              window: name,
              label: label,
              scope: scope,
              priority: priority,
              coverage: :empty_supported,
              used_percent: nil,
              resets_at: nil
            }
          ]
        else
          []
        end
    end
  end

  defp parse_reset(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _invalid -> nil
    end
  end

  defp parse_reset(_value), do: nil

  # --- credentials ---------------------------------------------------------

  defp read_file(path) do
    case File.read(path) do
      {:ok, raw} -> {:ok, raw}
      {:error, _reason} -> {:error, :no_credentials}
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, json} when is_map(json) -> {:ok, json}
      _invalid -> {:error, :malformed_credentials}
    end
  end

  # `expiresAt` is epoch milliseconds. An expired token would 401; skipping the
  # request is cheaper and keeps the failure quiet. A zero (or negative) expiry
  # is what a signed-out Claude Code writes, and must read as already expired
  # rather than "no expiry".
  defp expired?(%{"expiresAt" => expires_at}, now_ms) when is_integer(expires_at) and expires_at > 0,
    do: expires_at <= now_ms

  defp expired?(%{"expiresAt" => expires_at}, _now_ms) when is_integer(expires_at), do: true
  defp expired?(_oauth, _now_ms), do: false
end
