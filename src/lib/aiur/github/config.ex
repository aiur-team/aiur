defmodule Aiur.GitHub.Config do
  @moduledoc """
  GitHub-specific configuration read from the `github:` YAML section.
  """

  @behaviour Aiur.TrackerConfig

  @default_label_prefix "agent"

  @spec repo() :: String.t() | nil
  def repo do
    case section_value("repo") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> Aiur.Git.origin_repo()
          trimmed -> trimmed
        end

      _ ->
        # No repo in config (e.g. the general global config) — auto-detect
        # it from the current repo's git remote.
        Aiur.Git.origin_repo()
    end
  end

  @doc """
  Returns only the repository explicitly configured in `tracker.github.repo`.

  Unlike `repo/0`, this never falls back to the current checkout's git remote;
  callers using it are establishing a trusted cross-repository identity.
  """
  @spec configured_repo() ::
          {:ok, {String.t(), String.t()}}
          | {:error, :missing_configured_repository | :invalid_configured_repository}
  def configured_repo do
    case section_value("repo") do
      value when is_binary(value) -> parse_configured_repo(value)
      _ -> {:error, :missing_configured_repository}
    end
  end

  @spec token() :: String.t() | nil
  def token do
    case :persistent_term.get({__MODULE__, :resolved_token}, :unset) do
      :unset -> normalize_secret(System.get_env("GITHUB_TOKEN"))
      resolved -> resolved
    end
  end

  @doc """
  Resolve the GitHub token once at startup: prefer a VALID `GITHUB_TOKEN` env
  var, but fall back to the gh keyring when the env token is absent or invalid
  (e.g. a stale token sourced from .env). Caches the result; `token/0` returns it.
  """
  @spec resolve_token(keyword()) :: String.t() | nil
  def resolve_token(opts \\ []) do
    request_fun = Keyword.get(opts, :request_fun, &Req.get/2)

    validate =
      Keyword.get(opts, :validate_fun, fn token ->
        valid_github_token?(token, request_fun)
      end)

    keyring = Keyword.get(opts, :keyring_fun, &keyring_token/0)
    env = normalize_secret(System.get_env("GITHUB_TOKEN"))

    resolved =
      cond do
        is_binary(env) and validate.(env) -> env
        (kt = keyring.()) && is_binary(kt) && validate.(kt) -> kt
        true -> env
      end

    # Only cache a real token; caching nil would shadow a later GITHUB_TOKEN
    # (e.g. per-test env), since token/0 treats a cached nil as resolved.
    if is_binary(resolved), do: :persistent_term.put({__MODULE__, :resolved_token}, resolved)
    resolved
  end

  @spec label_prefix() :: String.t()
  def label_prefix do
    case section_value("label_prefix") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> @default_label_prefix
          trimmed -> trimmed
        end

      _ ->
        @default_label_prefix
    end
  end

  @doc """
  Returns the GitHub login that Aiur posts under (PR comments, dependency
  declarations, etc.). Read from `github.bot_account` in .aiurconfig.
  Returns `nil` when unset — `validate!/0` does not require it, since
  bot identity is only load-bearing for the events foundation (CODEOWNERS
  allowlist self-include + native dependency authorship).
  """
  @spec bot_account() :: String.t() | nil
  def bot_account do
    case section_value("bot_account") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @doc """
  Returns additional GitHub logins whose comments are trusted for agent
  delivery without treating them as Aiur self-loop authors.
  """
  @spec trusted_accounts() :: [String.t()]
  def trusted_accounts do
    case section_value("trusted_accounts") do
      accounts when is_list(accounts) ->
        accounts
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq_by(&String.downcase/1)

      account when is_binary(account) ->
        case String.trim(account) do
          "" -> []
          trimmed -> [trimmed]
        end

      _ ->
        []
    end
  end

  @doc """
  Whether opt-in repo-wide PR comment watching is enabled (`pr_watch.enabled`).
  When false, aiur only reacts to comments on its own `aiur/<id>` PRs.
  """
  @spec pr_watch_enabled?() :: boolean()
  def pr_watch_enabled? do
    Aiur.Config.settings!().pr_watch.enabled
  end

  @doc """
  The fully-qualified opt-in watch label (e.g. `agent:watch`), combining the
  github `label_prefix/0` with `pr_watch.watch_label`.
  """
  @spec watch_label() :: String.t()
  def watch_label do
    "#{label_prefix()}:#{Aiur.Config.settings!().pr_watch.watch_label}"
  end

  @doc """
  The one-off per-comment command prefix (e.g. `/aiur`). A trusted comment
  starting with this — or mentioning `bot_account/0` — wakes an agent for that
  single comment, no label required.
  """
  @spec command_prefix() :: String.t()
  def command_prefix do
    Aiur.Config.settings!().pr_watch.command_prefix
  end

  @impl Aiur.TrackerConfig
  def validate! do
    cond do
      !is_binary(token()) ->
        {:error, "GitHub token missing — set GITHUB_TOKEN env var"}

      !is_binary(repo()) ->
        {:error, "GitHub repo missing — set github.repo in .aiurconfig"}

      true ->
        :ok
    end
  end

  defp section_value(key) do
    Aiur.Config.settings!().tracker.github
    |> Map.from_struct()
    |> Map.get(String.to_existing_atom(key))
  end

  defp parse_configured_repo(value) do
    case String.split(String.trim(value), "/") do
      [owner, repo] when owner != "" and repo != "" -> {:ok, {owner, repo}}
      _ -> {:error, :invalid_configured_repository}
    end
  end

  # Query the gh keyring with the env tokens CLEARED so gh returns the stored
  # login rather than echoing the (possibly stale) env var. nil when gh is
  # absent or not logged in via keyring (headless/CI).
  defp keyring_token do
    case System.cmd("gh", ["auth", "token", "--hostname", "github.com"],
           env: [{"GITHUB_TOKEN", ""}, {"GH_TOKEN", ""}],
           stderr_to_stdout: true
         ) do
      {out, 0} -> normalize_secret(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Cheap validity probe: GET /rate_limit returns 200 for a syntactically usable
  # token, but an exhausted core quota still wedges the fleet (#617). Treat a
  # 200 response with remaining=0 as unusable so boot can fall back from a stale
  # `.env` token to `gh` keyring auth when available.
  defp valid_github_token?(token, request_fun) when is_binary(token) and is_function(request_fun, 2) do
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
