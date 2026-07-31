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

  # Windows the endpoint reports. The worst-consumed one is what will stop work
  # first, so it is the honest single number for a meter.
  @windows ~w(five_hour seven_day seven_day_opus seven_day_sonnet)

  @type reading :: %{
          used_percent: number(),
          resets_at: DateTime.t() | nil,
          window: String.t()
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
         {:ok, json} <- decode(raw),
         %{"accessToken" => token} = oauth when is_binary(token) <- Map.get(json, "claudeAiOauth", %{}),
         false <- token == "",
         false <- expired?(oauth, now_ms) do
      {:ok, token}
    else
      true -> {:error, :token_expired}
      {:error, reason} -> {:error, reason}
      _missing -> {:error, :no_oauth_token}
    end
  end

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

  @doc false
  @spec select_window(map()) :: {:ok, reading()} | {:error, :no_utilization}
  def select_window(body) when is_map(body) do
    @windows
    |> Enum.flat_map(&window_reading(body, &1))
    |> Enum.max_by(& &1.used_percent, fn -> nil end)
    |> case do
      nil -> {:error, :no_utilization}
      reading -> {:ok, reading}
    end
  end

  def select_window(_body), do: {:error, :no_utilization}

  defp window_reading(body, name) do
    case Map.get(body, name) do
      %{"utilization" => percent} = window when is_number(percent) and percent >= 0 ->
        [%{used_percent: min(percent, 100), resets_at: parse_reset(Map.get(window, "resets_at")), window: name}]

      _absent_or_unusable ->
        []
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
  # request is cheaper and keeps the failure quiet.
  defp expired?(%{"expiresAt" => expires_at}, now_ms) when is_integer(expires_at), do: expires_at <= now_ms
  defp expired?(_oauth, _now_ms), do: false
end
