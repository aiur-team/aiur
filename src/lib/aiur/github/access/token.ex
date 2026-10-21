defmodule Aiur.GitHub.Access.Token do
  @moduledoc "Resolves GitHub credentials and their daemon identity."
  require Logger
  alias Aiur.GitHub.{AppCredentials, AppToken, AppTokenRefresher, Transport}

  @spec token() :: String.t() | nil
  def token do
    if AppCredentials.configured?() do
      AppTokenRefresher.current_token()
    else
      case :persistent_term.get({__MODULE__, :resolved_token}, :unset) do
        :unset -> normalize_secret(System.get_env("GITHUB_TOKEN"))
        resolved -> resolved
      end
    end
  end

  @doc """
  Resolve the GitHub token once at startup.

  When GitHub App credentials are configured (`GITHUB_APP_ID`,
  `GITHUB_APP_INSTALLATION_ID` and the App private key), acquires and caches a
  short-lived installation token synchronously — the App-token analogue of the
  PAT path's boot-time rate-limit probe — so the pollers never start without a
  credential. On failure it logs a warning and returns nil without crashing
  boot; the `Aiur.GitHub.AppTokenRefresher` keeps retrying and raising
  needs-attention alerts.

  Otherwise prefers a VALID `GITHUB_TOKEN` env var, but falls back to the gh
  keyring when the env token is absent or invalid (e.g. a stale token sourced
  from .env). Caches the result; `token/0` returns it.
  """
  @spec resolve_token(keyword()) :: String.t() | nil
  def resolve_token(opts \\ []) do
    if AppCredentials.configured?() do
      resolve_installation_token(opts)
    else
      resolve_pat_token(opts)
    end
  end

  defp resolve_installation_token(opts) do
    request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
    validate_fun = Keyword.get(opts, :validate_fun, &AppToken.rate_limit_usable?/2)
    acquire_fun = Keyword.get(opts, :acquire_fun, &AppToken.acquire/1)

    case acquire_fun.(request_fun: request_fun, validate_fun: validate_fun) do
      {:ok, %{token: token, expires_at: expires_at, permissions: permissions}}
      when is_binary(token) and token != "" ->
        :ok = AppTokenRefresher.cache_token(token, expires_at, permissions)
        token

      {:error, reason} ->
        # Sanitized: the raw reason can carry the private-key file path.
        sanitized = AppCredentials.sanitize_error(reason)
        Logger.warning("aiur_boot phase=github_app_token_resolve_failed reason=#{inspect(sanitized)}")
        nil
    end
  end

  defp resolve_pat_token(opts) do
    request_fun = Keyword.get(opts, :request_fun, &Req.get/2)

    validate =
      Keyword.get(opts, :validate_fun, fn token ->
        valid_github_token?(token, request_fun)
      end)

    keyring = Keyword.get(opts, :keyring_fun, &keyring_token/0)
    env = normalize_secret(System.get_env("GITHUB_TOKEN"))

    {resolved, source} =
      cond do
        is_binary(env) and validate.(env) -> {env, :env}
        (kt = keyring.()) && is_binary(kt) && validate.(kt) -> {kt, :keyring}
        true -> {env, if(is_binary(env), do: :env, else: :none)}
      end

    # Only cache a real token; caching nil would shadow a later GITHUB_TOKEN
    # (e.g. per-test env), since token/0 treats a cached nil as resolved.
    if is_binary(resolved) do
      :persistent_term.put({__MODULE__, :resolved_token}, resolved)
      :persistent_term.put({__MODULE__, :resolved_token_source}, source)
    end

    resolved
  end

  @doc """
  The source the currently-resolved GitHub token was obtained from:
  `:github_app` (App installation token), `:env` (`GITHUB_TOKEN`), `:keyring`
  (the `gh` keyring from `gh auth login`), or `:none`.

  The env var is always the source of truth for a token read straight from
  `GITHUB_TOKEN` before `resolve_token/1` runs; once a token has been resolved
  this reports where that resolution actually found a usable credential.
  """
  @spec token_source() :: :github_app | :env | :keyring | :none
  def token_source do
    cond do
      AppCredentials.configured?() ->
        :github_app

      (source = :persistent_term.get({__MODULE__, :resolved_token_source}, nil)) in [:env, :keyring] ->
        source

      nonblank_token?(System.get_env("GITHUB_TOKEN")) ->
        :env

      true ->
        :none
    end
  end

  defp nonblank_token?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonblank_token?(_value), do: false

  @spec app_account() :: String.t() | nil
  def app_account, do: normalize_account(Aiur.GitHub.Access.Settings.current().app_account)

  @spec daemon_account() :: String.t() | nil
  def daemon_account, do: app_account() || normalize_account(Aiur.GitHub.Access.Settings.current().bot_account)

  @spec app_identity_issue() :: nil | :bot_account_missing | {:bot_account_not_app_bot, String.t()}
  def app_identity_issue do
    if AppCredentials.configured?(), do: bot_account_issue(daemon_account())
  end

  defp bot_account_issue(nil), do: :bot_account_missing

  defp bot_account_issue(login) do
    unless String.ends_with?(String.downcase(login), "[bot]"), do: {:bot_account_not_app_bot, login}
  end

  defp normalize_account(value) when is_binary(value), do: normalize_secret(value)
  defp normalize_account(_value), do: nil

  @spec keyring_command_timeout_ms() :: pos_integer()
  defdelegate keyring_command_timeout_ms(), to: Aiur.GitHub.Access.Keyring

  @spec keyring_timeout_ms(keyword()) :: pos_integer()
  defdelegate keyring_timeout_ms(opts \\ []), to: Aiur.GitHub.Access.Keyring

  @spec keyring_token(keyword()) :: String.t() | nil
  defdelegate keyring_token(opts \\ []), to: Aiur.GitHub.Access.Keyring

  @spec kill_os_process(term(), keyword()) :: :ok
  defdelegate kill_os_process(pid, opts \\ []), to: Aiur.GitHub.Access.Keyring
  # Cheap validity probe: GET /rate_limit returns 200 for a syntactically usable
  # token, but an exhausted core quota still wedges the fleet (#617). Treat a
  # 200 response with remaining=0 as unusable so boot can fall back from a stale
  # `.env` token to `gh` keyring auth when available.
  defp valid_github_token?(token, request_fun)
       when is_binary(token) and is_function(request_fun, 2) do
    case request_fun.("https://api.github.com/rate_limit",
           headers: [
             {"Authorization", "Bearer #{token}"},
             {"Accept", "application/vnd.github+json"},
             {"User-Agent", "aiur"}
           ],
           connect_options: [timeout: 10_000]
         ) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        rate_limit_usable?(response)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp valid_github_token?(_, _), do: false

  defp rate_limit_usable?(response) do
    case rate_limit_remaining(response) do
      0 -> false
      _remaining -> true
    end
  end

  defp rate_limit_remaining(%{headers: headers} = response) do
    header_remaining(headers) || body_remaining(response)
  end

  defp rate_limit_remaining(%{} = response), do: body_remaining(response)

  defp header_remaining(headers) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {key, value} ->
        if String.downcase(to_string(key)) == "x-ratelimit-remaining" do
          parse_integer(value)
        end

      _ ->
        nil
    end)
  end

  defp header_remaining(headers) when is_map(headers) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == "x-ratelimit-remaining" do
        parse_integer(value)
      end
    end)
  end

  defp header_remaining(_headers), do: nil

  defp body_remaining(%{body: %{"resources" => %{"core" => %{"remaining" => remaining}}}}),
    do: parse_integer(remaining)

  defp body_remaining(%{body: %{"rate" => %{"remaining" => remaining}}}),
    do: parse_integer(remaining)

  defp body_remaining(_response), do: nil

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer([value | _]), do: parse_integer(value)

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp normalize_secret(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_secret(_value), do: nil
end
