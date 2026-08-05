defmodule Aiur.GitHub.AppTokenRefresher do
  @moduledoc """
  Owns the daemon's GitHub App installation-token lifecycle.

  Acquires the installation token (reusing the one `Config.resolve_token/1`
  cached at boot when present), refreshes it before its ~1 hour expiry, and
  reports problems as Executor-visible needs-attention alerts:

    * a refresh failure emits `system.github_app_token.refresh_failed` and
      retries with capped backoff, once per failure episode (a recovery
      re-arms it);
    * a granted permission set beyond the least-privilege posture emits
      `system.github_app_token.permission_violation` whenever the violation
      changes.

  The current token is served synchronously from `:persistent_term` via
  `current_token/0`, so `GitHub.Config.token/0` never blocks on this GenServer
  and still has a value before the supervision tree starts (the boot-time
  `resolve_token/1` caches it). No code path here logs or emits the raw token
  or private key.

  When no GitHub App credentials are configured the process starts disabled and
  is fully inert — no timer, no acquisition, no alerts — leaving the
  `GITHUB_TOKEN` PAT path in charge.
  """

  use GenServer

  require Logger

  alias Aiur.GitHub.{AppCredentials, AppToken, Config, Transport}

  @token_key {__MODULE__, :installation_token}
  @min_refresh_ms 1_000
  @retry_backoff_ms 60_000
  @max_retry_backoff_ms 300_000
  @refresh_failed_topic "system.github_app_token.refresh_failed"
  @permission_violation_topic "system.github_app_token.permission_violation"
  @refresh_recovered_topic "system.github_app_token.refresh_recovered"
  @identity_mismatch_topic "system.github_app_token.identity_mismatch"

  @type state :: %{
          enabled: boolean(),
          request_fun: function(),
          emit_fun: function(),
          consecutive_failures: non_neg_integer(),
          alerted: boolean(),
          violation: map() | nil,
          refresh_timer: reference() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  ## ---- Synchronous cache access (no GenServer dependency) ----

  @doc "The currently cached installation token, or nil when none is available."
  @spec current_token() :: String.t() | nil
  def current_token do
    case :persistent_term.get(@token_key, :unset) do
      {:installation_token, token, _expires_at, _permissions} when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  @doc "The cached installation token's expiry, or nil."
  @spec current_expires_at() :: DateTime.t() | nil
  def current_expires_at do
    case :persistent_term.get(@token_key, :unset) do
      {:installation_token, _token, expires_at, _permissions} when is_struct(expires_at, DateTime) -> expires_at
      _ -> nil
    end
  end

  @doc """
  Caches a freshly acquired installation token. Public so the boot-time
  `Config.resolve_token/1` path and tests can populate the same cache the
  refresher manages; never logs the token.
  """
  @spec cache_token(String.t(), DateTime.t(), map()) :: :ok
  def cache_token(token, expires_at, permissions)
      when is_binary(token) and token != "" and is_struct(expires_at, DateTime) and is_map(permissions) do
    :persistent_term.put(@token_key, {:installation_token, token, expires_at, permissions})
    :ok
  end

  @doc "Clears the cached installation token."
  @spec clear_token() :: :ok
  def clear_token do
    :persistent_term.erase(@token_key)
    :ok
  end

  ## ---- GenServer ----

  @impl true
  def init(opts) do
    request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
    emit_fun = Keyword.get(opts, :emit_fun, &Aiur.Alerts.emit_custom/3)

    state = %{
      enabled: AppCredentials.configured?(),
      request_fun: request_fun,
      emit_fun: emit_fun,
      consecutive_failures: 0,
      alerted: false,
      violation: nil,
      refresh_timer: nil
    }

    if state.enabled, do: check_identity(state)

    state =
      if state.enabled do
        if current_token() do
          # Boot-time resolve_token/1 already cached a token; keep it and just
          # schedule the refresh from its expiry.
          state
        else
          ensure_token(state)
        end
      else
        state
      end

    {:ok, schedule_initial(state)}
  end

  @impl true
  def handle_info(:refresh, state) do
    {:noreply, do_refresh(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state)
    :ok
  end

  # Disabled (no App credentials configured) refreshers are inert: no timer is
  # scheduled at init and any stray :refresh message is ignored, so a disabled
  # process can never acquire, retry, or alert.
  defp do_refresh(%{enabled: false} = state), do: state

  defp do_refresh(state) do
    case AppToken.acquire(request_fun: state.request_fun) do
      {:ok, result} ->
        handle_success(result, state)

      {:error, reason} ->
        handle_failure(reason, state)
    end
    |> schedule_next()
  end

  defp handle_success(%{token: token, expires_at: expires_at, permissions: permissions} = result, state) do
    :ok = cache_token(token, expires_at, permissions)
    Logger.info("github_app_token refreshed expires_at=#{DateTime.to_iso8601(expires_at)}")
    maybe_emit_recovery(state)

    violation = Map.get(result, :permission_violation)

    handle_violation(violation, state)
    |> Map.put(:consecutive_failures, 0)
    |> Map.put(:alerted, false)
  end

  defp handle_failure(reason, state) do
    consecutive = state.consecutive_failures + 1
    maybe_emit_refresh_failure(reason, state)

    %{state | consecutive_failures: consecutive, alerted: true}
  end

  # One needs-attention alert per failure episode: the first failure in a run,
  # then silence until a refresh succeeds again (which re-arms via
  # `alerted: false`).
  defp maybe_emit_refresh_failure(reason, %{alerted: false} = state) do
    message =
      "GitHub App installation token refresh failed (#{describe_reason(reason)}). " <>
        "The daemon retries automatically with backoff. Verify GITHUB_APP_ID, " <>
        "GITHUB_APP_INSTALLATION_ID and the App private key, and that the App is " <>
        "installed with only Contents: write, Issues: read/write, Pull requests: write."

    safe_emit(state, @refresh_failed_topic, message)
  end

  defp maybe_emit_refresh_failure(_reason, %{alerted: true}), do: :ok

  defp maybe_emit_recovery(%{alerted: true} = state) do
    safe_emit(
      state,
      @refresh_recovered_topic,
      "GitHub App installation token refresh recovered.",
      needs_attention: false,
      severity: "info"
    )
  end

  defp maybe_emit_recovery(_state), do: :ok

  # Emit a needs-attention alert when the permission violation first appears or
  # changes; a stable violation is not re-alerted on every hourly refresh.
  # Returns the state with `violation` set to the current (possibly nil) value.
  defp handle_violation(violation, state) do
    if violation != state.violation do
      if violation do
        safe_emit(
          state,
          @permission_violation_topic,
          "GitHub App installation token grants permissions beyond the least-privilege set: " <>
            "#{inspect(violation.extra_permissions)}. Revoke them in the GitHub App settings — " <>
            "only Contents: write, Issues: read/write, Pull requests: write are allowed."
        )
      end

      %{state | violation: violation}
    else
      state
    end
  end

  # Under App auth the daemon writes as the App bot (`<slug>[bot]`), so a
  # `bot_account` still naming the PAT account breaks every self-loop and
  # authorship gate that compares against it. Checked once at startup and
  # raised as needs-attention rather than left to be discovered as the daemon
  # reacting to its own comments.
  defp check_identity(state) do
    case identity_issue() do
      nil ->
        :ok

      :bot_account_missing ->
        safe_emit(
          state,
          @identity_mismatch_topic,
          "GitHub App authentication is configured but tracker.github.bot_account is unset. " <>
            "Set it to the App's bot login (`<app-slug>[bot]`) — self-loop suppression, PR " <>
            "command handling, and reply verification all key off it and are inert while it is nil."
        )

      {:bot_account_not_app_bot, login} ->
        safe_emit(
          state,
          @identity_mismatch_topic,
          "tracker.github.bot_account is `#{login}`, but the daemon now authenticates as a GitHub " <>
            "App and writes as the App's bot user (`<app-slug>[bot]`). Update bot_account to the " <>
            "App bot login, or the daemon will not recognize its own comments, labels and PRs."
        )
    end
  end

  # Reading `bot_account` goes through the loaded settings; if they are not
  # available the identity check simply does not run, rather than taking the
  # token refresher down with it.
  defp identity_issue do
    Config.app_identity_issue()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp ensure_token(state) do
    case AppToken.acquire(request_fun: state.request_fun) do
      {:ok, %{token: token, expires_at: expires_at, permissions: permissions} = result} ->
        :ok = cache_token(token, expires_at, permissions)

        violation = Map.get(result, :permission_violation)
        handle_violation(violation, state)

      {:error, reason} ->
        Logger.warning("github_app_token boot_acquire_failed reason=#{describe_reason(reason)}")
        handle_failure(reason, state)
    end
  end

  defp schedule_initial(state) do
    if state.enabled, do: schedule_from_expiry(state), else: state
  end

  defp schedule_next(state) do
    if state.enabled do
      case state.consecutive_failures do
        0 -> schedule_from_expiry(state)
        n -> schedule_retry(state, n)
      end
    else
      state
    end
  end

  # Timer driven off the cached token's expiry minus a safety margin, so a
  # successful refresh always lands comfortably before the ~1h expiry.
  defp schedule_from_expiry(state) do
    delay =
      case current_expires_at() do
        expires_at when is_struct(expires_at, DateTime) -> AppToken.refresh_delay_ms(expires_at)
        _ -> @min_refresh_ms
      end

    reschedule(state, delay)
  end

  defp schedule_retry(state, consecutive) do
    delay = min(@retry_backoff_ms * 2 ** (consecutive - 1), @max_retry_backoff_ms)
    reschedule(state, delay)
  end

  defp reschedule(state, delay) do
    cancel_timer(state)
    timer = Process.send_after(self(), :refresh, delay)
    %{state | refresh_timer: timer}
  end

  defp cancel_timer(%{refresh_timer: nil}), do: :ok

  defp cancel_timer(%{refresh_timer: timer}) do
    Process.cancel_timer(timer)
    :ok
  end

  defp safe_emit(%{emit_fun: emit_fun}, topic, message, opts \\ []) do
    emit_fun.(topic, message,
      reason: message,
      needs_attention: Keyword.get(opts, :needs_attention, true),
      severity: Keyword.get(opts, :severity, "warning")
    )
  end

  # Structural, secret-free description of an acquisition/refresh failure.
  defp describe_reason(:installation_token_rate_limited),
    do: "the installation token's rate limit is exhausted"

  defp describe_reason(:missing_app_id), do: "GITHUB_APP_ID is not set"
  defp describe_reason(:missing_installation_id), do: "GITHUB_APP_INSTALLATION_ID is not set"
  defp describe_reason(:missing_private_key), do: "the App private key is not configured"
  defp describe_reason(:invalid_private_key), do: "the App private key is not a valid PEM"
  defp describe_reason({:private_key_path_unreadable, _path, reason}), do: "the App private key file could not be read (#{reason})"

  defp describe_reason({:github, :auth, _detail}), do: "GitHub rejected the App JWT (invalid app id or private key)"
  defp describe_reason({:github, :rate_limited, _detail}), do: "GitHub rate-limited the access-token exchange"
  defp describe_reason({:github, :http, %{status: status}}), do: "GitHub returned HTTP #{status} for the access-token exchange"

  defp describe_reason({:github, classification, _detail}) when classification in [:dns, :timeout, :tls, :transport],
    do: "the access-token exchange failed before GitHub returned a status (#{classification})"

  defp describe_reason(reason), do: "unexpected failure (#{inspect(reason)})"
end
