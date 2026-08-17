defmodule Aiur.Codeowners do
  @moduledoc """
  Reads GitHub CODEOWNERS files and classifies comment authors.
  """

  alias Aiur.GitHub
  alias Aiur.GitHub.CodeOwners
  alias Aiur.GitHub.Transport

  @type owner_entry :: %{
          required(:handle) => String.t(),
          required(:usernames) => [String.t()],
          required(:pattern) => String.t(),
          required(:path) => String.t() | nil
        }

  @type ownership_context :: %{
          required(:codeowners_present) => boolean(),
          required(:owners) => [String.t()],
          required(:entries) => [owner_entry()],
          optional(:agent_logins) => [String.t()]
        }

  @type ownership_error :: :quota_hold | {:github_api_status, non_neg_integer()} | {:github_api_request, term()}

  @codeowners_paths [
    ".github/CODEOWNERS",
    "CODEOWNERS",
    "docs/CODEOWNERS"
  ]

  @base_url "https://api.github.com"

  @doc """
  Standard GitHub CODEOWNERS locations, in discovery order.
  """
  @spec standard_paths() :: [String.t()]
  def standard_paths, do: @codeowners_paths

  @doc """
  Finds the repo root used for CODEOWNERS discovery.
  """
  @spec repo_root(Path.t()) :: Path.t()
  def repo_root(path \\ File.cwd!()), do: discover_repo_root(path)

  @doc """
  Returns the active CODEOWNERS file path, if one exists.
  """
  @spec file_path(keyword()) :: Path.t() | nil
  def file_path(opts \\ []) do
    repo_root = Keyword.get(opts, :repo_root) || repo_root(File.cwd!())

    Enum.find_value(@codeowners_paths, fn relative_path ->
      full_path = Path.join(repo_root, relative_path)
      if File.regular?(full_path), do: full_path
    end)
  end

  @doc """
  Returns usernames responsible for a path.

  Team owners are expanded to member usernames when a token and request
  function are available. If no CODEOWNERS file exists or no rule matches,
  this returns an empty list, and `authoritative?/2` then trusts nobody —
  see the fail-closed invariant there.

  If a team cannot be expanded — a quota hold is the common cause — this
  returns an error instead, so callers do not mistake unknown ownership for
  no owners.
  """
  @spec owners_for_path(String.t(), keyword()) :: [String.t()] | {:error, ownership_error()}
  def owners_for_path(path, opts \\ []) when is_binary(path) do
    path
    |> ownership_for_path(opts)
    |> owners_from_context()
  end

  @doc """
  Returns usernames responsible for any changed path in a pull request.

  Pass `changed_paths: [...]` to avoid a GitHub API call, or pass a PR number
  with repository configuration available. GitHub lookup failures are returned
  rather than collapsed into an empty owner list.
  """
  @spec owners_for_pr(String.t() | integer() | [String.t()], keyword()) :: [String.t()] | {:error, term()}
  def owners_for_pr(pr_or_paths, opts \\ []) do
    cond do
      is_list(pr_or_paths) ->
        pr_or_paths
        |> ownership_for_paths(opts)
        |> owners_from_context()

      is_binary(pr_or_paths) or is_integer(pr_or_paths) ->
        case Keyword.get(opts, :changed_paths) || fetch_pr_changed_paths(pr_or_paths, opts) do
          {:error, reason} -> normalize_ownership_error(reason)
          paths when is_list(paths) -> owners_for_pr(paths, opts)
        end
    end
  end

  @doc """
  Returns whether `commenter` is authoritative in the supplied context.

  The second argument may be:
  - an ownership context from `ownership_for_path/2` or `ownership_for_paths/2`
  - a list of owner usernames
  - a keyword list with `:path`, `:changed_paths`, `:owners`, and/or
    `:agent_logins`
  """
  @spec authoritative?(String.t() | nil, ownership_context() | {:error, term()} | [String.t()] | keyword()) :: boolean() | nil
  def authoritative?(commenter, _context) when not is_binary(commenter), do: false

  def authoritative?(_commenter, {:error, _reason}), do: nil

  def authoritative?(commenter, context) when is_map(context) do
    cond do
      agent_login?(commenter, Map.get(context, :agent_logins, [])) ->
        false

      # SECURITY INVARIANT — never trust everyone. This used to return `true`,
      # which made EVERY commenter authoritative in any repository without a
      # CODEOWNERS file: an outsider's comment on a public repo was accepted as
      # a trusted instruction to the agent.
      #
      # Degraded mode has exactly one owner, `Aiur.GitHub.CodeOwners`, which
      # resolves `bot_account` + `trusted_accounts` (falling back to the repo
      # owner when neither is configured) and alerts the Executor. Delegating
      # there rather than answering `false` outright matters: a flat `false`
      # would silently drop every comment — including the operator's own — from
      # the agent digest and make review threads permanently unresolvable, so
      # the fail-closed gate would present as a hang with no alert.
      #
      # When that process is not running (test harnesses, early boot) there is
      # no trust source to consult, and the answer is `false`. Do not
      # reintroduce a local fallback here: two modules disagreeing about who is
      # trusted is how this became exploitable in the first place.
      Map.get(context, :codeowners_present) == false ->
        degraded_mode_trusted?(commenter, Map.get(context, :trust_server, CodeOwners))

      true ->
        normalized_member?(commenter, Map.get(context, :owners, []))
    end
  end

  def authoritative?(commenter, context) when is_list(context) do
    cond do
      context == [] ->
        false

      Keyword.keyword?(context) ->
        authoritative?(commenter, context_from_opts(context))

      true ->
        normalized_member?(commenter, context)
    end
  end

  @doc """
  Returns ownership metadata for a path, including the matched pattern.
  """
  @spec ownership_for_path(String.t(), keyword()) :: ownership_context() | {:error, ownership_error()}
  def ownership_for_path(path, opts \\ []) when is_binary(path) do
    codeowners = read_codeowners(opts)

    if codeowners.present? do
      entries_result =
        codeowners.rules
        |> matching_rule(path)
        |> entries_for_rule(path, opts)

      ownership_context(entries_result)
    else
      %{codeowners_present: false, owners: [], entries: []}
    end
  end

  @doc """
  Returns ownership metadata for multiple paths.
  """
  @spec ownership_for_paths([String.t()], keyword()) :: ownership_context() | {:error, ownership_error()}
  def ownership_for_paths(paths, opts \\ []) when is_list(paths) do
    codeowners = read_codeowners(opts)

    if codeowners.present? do
      paths
      |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
        case codeowners.rules |> matching_rule(path) |> entries_for_rule(path, opts) do
          {:ok, entries} -> {:cont, {:ok, entries ++ acc}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> ownership_context()
    else
      %{codeowners_present: false, owners: [], entries: []}
    end
  end

  @doc """
  Returns ownership metadata for all owners in the active CODEOWNERS file.
  """
  @spec repo_ownership(keyword()) :: ownership_context() | {:error, ownership_error()}
  def repo_ownership(opts \\ []) do
    codeowners = read_codeowners(opts)

    if codeowners.present? do
      codeowners.rules
      |> Enum.reduce_while({:ok, []}, fn rule, {:ok, acc} ->
        case entries_for_rule(rule, nil, opts) do
          {:ok, entries} -> {:cont, {:ok, entries ++ acc}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> ownership_context()
    else
      %{codeowners_present: false, owners: [], entries: []}
    end
  end

  @doc """
  Adds authoritative/advisory metadata to a comment map.
  """
  @spec classify_comment(map(), ownership_context() | {:error, term()}, keyword()) :: map()
  def classify_comment(comment, ownership_context, opts \\ [])

  def classify_comment(comment, {:error, reason}, opts) when is_map(comment) do
    author = comment_author(comment)
    agent_comment? = agent_login?(author, Keyword.get(opts, :agent_logins, []))

    comment
    |> Map.put(:authoritative, if(agent_comment?, do: false, else: nil))
    |> Map.put(:authority_reason, unknown_authority_reason(reason, agent_comment?))
    |> Map.put(:codeowners, %{status: :unknown, reason: reason})
  end

  def classify_comment(comment, ownership_context, opts) when is_map(comment) and is_map(ownership_context) do
    author = comment_author(comment)
    context = Map.put(ownership_context, :agent_logins, Keyword.get(opts, :agent_logins, []))
    authoritative = authoritative?(author, context)

    comment
    |> Map.put(:authoritative, authoritative)
    |> Map.put(:authority_reason, authority_reason(author, context, authoritative))
    |> Map.put(:codeowners, Map.take(context, [:codeowners_present, :owners, :entries]))
  end

  defp context_from_opts(opts) do
    opts
    |> base_context_from_opts()
    |> put_trust_server(opts)
  end

  defp put_trust_server(context, opts) do
    case Keyword.get(opts, :trust_server) do
      nil -> context
      server -> Map.put(context, :trust_server, server)
    end
  end

  defp base_context_from_opts(opts) do
    cond do
      Keyword.has_key?(opts, :owners) ->
        %{
          codeowners_present: Keyword.get(opts, :codeowners_present, true),
          owners: Keyword.fetch!(opts, :owners),
          entries: Keyword.get(opts, :entries, []),
          agent_logins: Keyword.get(opts, :agent_logins, [])
        }

      path = Keyword.get(opts, :path) ->
        path
        |> ownership_for_path(opts)
        |> with_agent_logins(opts)

      paths = Keyword.get(opts, :changed_paths) ->
        paths
        |> ownership_for_paths(opts)
        |> with_agent_logins(opts)

      true ->
        opts
        |> repo_ownership()
        |> with_agent_logins(opts)
    end
  end

  # Defers to the one module that owns degraded-mode trust. Mirrors
  # `Aiur.Events.Sanitizer.author_trusted?/1`: absent process means no trust
  # source, which means no trust.
  defp degraded_mode_trusted?(commenter, server) do
    if is_pid(server) or Process.whereis(server) do
      CodeOwners.allowed?(commenter, server)
    else
      false
    end
  catch
    :exit, _reason -> false
  end

  defp with_agent_logins({:error, _reason} = error, _opts), do: error
  defp with_agent_logins(context, opts), do: Map.put(context, :agent_logins, Keyword.get(opts, :agent_logins, []))

  # A file that parses to no rules — most commonly the comments-only placeholder
  # `aiur init` writes when the operator declines to name an owner — grants
  # ownership to nobody. Treating it as "present" would fail closed while
  # reporting "author is not a CODEOWNER for the relevant paths", which sends
  # the next reader hunting for a rule that does not exist. It is the degraded
  # case, so say so.
  defp read_codeowners(opts) do
    with full_path when is_binary(full_path) <- file_path(opts),
         [_ | _] = rules <- parse_file!(full_path) do
      %{present?: true, rules: rules}
    else
      _absent_or_empty -> %{present?: false, rules: []}
    end
  end

  defp discover_repo_root(path) do
    path = Path.expand(path)
    parent = Path.dirname(path)

    cond do
      codeowners_root?(path) -> path
      git_root?(path) -> path
      parent == path -> path
      true -> discover_repo_root(parent)
    end
  end

  defp codeowners_root?(path) do
    Enum.any?(@codeowners_paths, &File.regular?(Path.join(path, &1)))
  end

  defp git_root?(path) do
    File.dir?(Path.join(path, ".git")) or File.regular?(Path.join(path, ".git"))
  end

  defp parse_file!(path) do
    path
    |> File.read!()
    |> String.split(~r/\R/, trim: true)
    |> Enum.flat_map(&parse_line/1)
  end

  defp parse_line(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" -> []
      String.starts_with?(trimmed, "#") -> []
      true -> line_tokens(trimmed) |> rule_from_tokens()
    end
  end

  defp line_tokens(line) do
    line
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take_while(&(not String.starts_with?(&1, "#")))
  end

  defp rule_from_tokens([pattern | owners]) do
    if valid_pattern?(pattern) and owners != [] do
      [%{pattern: pattern, owners: owners}]
    else
      []
    end
  end

  defp rule_from_tokens(_tokens), do: []

  defp valid_pattern?(pattern) do
    not String.starts_with?(pattern, "!") and not String.contains?(pattern, "[")
  end

  defp matching_rule(rules, path) do
    normalized_path = normalize_path(path)

    rules
    |> Enum.filter(&pattern_matches?(&1.pattern, normalized_path))
    |> List.last()
  end

  defp entries_for_rule(nil, _path, _opts), do: {:ok, []}

  defp entries_for_rule(%{pattern: pattern, owners: owners}, path, opts) do
    Enum.reduce_while(owners, {:ok, []}, fn owner, {:ok, entries} ->
      case usernames_for_owner(owner, opts) do
        {:ok, usernames} ->
          entry = %{handle: owner, usernames: usernames, pattern: pattern, path: path}
          {:cont, {:ok, [entry | entries]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp usernames_for_owner("@" <> owner = handle, opts) do
    case String.split(owner, "/", parts: 2) do
      [_user] -> {:ok, [normalize_login(handle)]}
      [org, team_slug] -> team_members(org, team_slug, opts)
    end
  end

  defp usernames_for_owner(owner, _opts), do: {:ok, [normalize_login(owner)]}

  defp team_members(org, team_slug, opts) do
    cache_key = {__MODULE__, :team_members, String.downcase(org), String.downcase(team_slug)}

    case Process.get(cache_key) do
      nil ->
        case fetch_team_members(org, team_slug, opts) do
          {:ok, members} ->
            Process.put(cache_key, members)
            {:ok, members}

          {:error, _reason} = error ->
            error
        end

      members ->
        {:ok, members}
    end
  end

  defp fetch_team_members(org, team_slug, opts) do
    request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
    token = Keyword.get_lazy(opts, :token, &GitHub.Config.token/0)
    url = "#{@base_url}/orgs/#{org}/teams/#{team_slug}/members?per_page=100"

    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        logins =
          body
          |> Enum.map(&Map.get(&1, "login"))
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&normalize_login/1)

        {:ok, logins}

      {:ok, %{status: status}} ->
        normalize_ownership_error({:github_api_status, status})

      {:error, reason} ->
        {:error, {:github_api_request, reason}}

      _invalid_response ->
        {:error, {:github_api_request, :invalid_response}}
    end
  end

  defp ownership_context({:error, _reason} = error), do: error

  defp ownership_context({:ok, entries}) do
    entries = entries |> Enum.reverse() |> uniq_entries()
    %{codeowners_present: true, owners: usernames(entries), entries: entries}
  end

  defp owners_from_context({:error, _reason} = error), do: error
  defp owners_from_context(context), do: Map.fetch!(context, :owners)

  defp normalize_ownership_error({:github_api_status, 429}), do: {:error, :quota_hold}
  defp normalize_ownership_error({:github_api_status, status}), do: {:error, {:github_api_status, status}}
  defp normalize_ownership_error(reason), do: {:error, reason}

  defp fetch_pr_changed_paths(pr_number, opts) do
    with {:ok, {owner, repo}} <- parse_repo(opts),
         token when is_binary(token) <- Keyword.get_lazy(opts, :token, &GitHub.Config.token/0) do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      url = "#{@base_url}/repos/#{owner}/#{repo}/pulls/#{pr_number}/files?per_page=100"

      case request_fun.(%{method: :get, url: url, token: token}) do
        {:ok, %{status: 200, body: body}} when is_list(body) ->
          body
          |> Enum.map(&Map.get(&1, "filename"))
          |> Enum.reject(&is_nil/1)

        {:ok, %{status: status}} ->
          {:error, {:github_api_status, status}}

        {:error, reason} ->
          {:error, {:github_api_request, reason}}
      end
    else
      nil -> {:error, :missing_github_token}
      error -> error
    end
  end

  defp parse_repo(opts) do
    repo_string = Keyword.get_lazy(opts, :repo, &GitHub.Config.repo/0)

    case repo_string do
      nil ->
        {:error, :missing_github_repo}

      repo_string ->
        case String.split(repo_string, "/") do
          [owner, repo] -> {:ok, {owner, repo}}
          _ -> {:error, {:invalid_github_repo, repo_string}}
        end
    end
  end

  defp pattern_matches?(pattern, path) do
    pattern = String.trim(pattern)

    cond do
      pattern == "*" ->
        path != ""

      String.ends_with?(pattern, "/") ->
        directory_pattern_matches?(pattern, path)

      String.starts_with?(pattern, "/") ->
        pattern
        |> String.trim_leading("/")
        |> glob_match?(path)

      String.contains?(pattern, "/") ->
        glob_match?(pattern, path)

      true ->
        glob_match?(pattern, Path.basename(path))
    end
  end

  defp directory_pattern_matches?(pattern, path) do
    directory =
      pattern
      |> String.trim_leading("/")
      |> String.trim_trailing("/")

    path == directory or String.starts_with?(path, directory <> "/")
  end

  defp glob_match?(pattern, path) do
    pattern
    |> glob_regex()
    |> Regex.match?(path)
  end

  defp glob_regex(pattern) do
    pattern =
      pattern
      |> String.graphemes()
      |> glob_regex_parts([])
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    Regex.compile!("^" <> pattern <> "$")
  end

  defp glob_regex_parts([], acc), do: acc
  defp glob_regex_parts(["*", "*" | rest], acc), do: glob_regex_parts(rest, [".*" | acc])
  defp glob_regex_parts(["*" | rest], acc), do: glob_regex_parts(rest, ["[^/]*" | acc])
  defp glob_regex_parts(["?" | rest], acc), do: glob_regex_parts(rest, ["[^/]" | acc])
  defp glob_regex_parts([char | rest], acc), do: glob_regex_parts(rest, [Regex.escape(char) | acc])

  defp normalize_path(path) do
    path
    |> String.trim()
    |> String.trim_leading("./")
    |> String.trim_leading("/")
  end

  defp uniq_entries(entries) do
    Enum.uniq_by(entries, fn entry -> {entry.handle, entry.pattern, entry.path} end)
  end

  defp usernames(entries) do
    entries
    |> Enum.flat_map(& &1.usernames)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalized_member?(commenter, owners) do
    normalized = normalize_login(commenter)
    normalized in Enum.map(owners, &normalize_login/1)
  end

  defp agent_login?(commenter, agent_logins) do
    normalized_member?(commenter, agent_logins)
  end

  defp normalize_login("@" <> login), do: String.downcase(login)
  defp normalize_login(login) when is_binary(login), do: String.downcase(login)

  defp comment_author(comment) do
    get_in(comment, [:author, :login]) ||
      get_in(comment, ["author", "login"]) ||
      get_in(comment, [:user, :login]) ||
      get_in(comment, ["user", "login"]) ||
      Map.get(comment, :author) ||
      Map.get(comment, "author")
  end

  defp authority_reason(_author, %{codeowners_present: false}, true) do
    "No CODEOWNERS rules found; author is an explicitly configured trusted account."
  end

  defp authority_reason(author, context, true) do
    context.entries
    |> Enum.find(fn entry -> normalized_member?(author, entry.usernames) end)
    |> case do
      nil -> "Author is listed in CODEOWNERS."
      entry -> "CODEOWNER via #{entry.handle} for #{entry.pattern}#{path_suffix(entry.path)}."
    end
  end

  defp authority_reason(author, context, false) do
    cond do
      agent_login?(author, Map.get(context, :agent_logins, [])) ->
        "Agent's own comment; never authoritative."

      context.codeowners_present ->
        "Author is not a CODEOWNER for the relevant paths."

      true ->
        "No CODEOWNERS rules found; only explicitly configured trusted accounts are authoritative."
    end
  end

  defp unknown_authority_reason(_reason, true), do: "Agent's own comment; never authoritative."
  defp unknown_authority_reason(:quota_hold, false), do: "CODEOWNER authority is unknown because GitHub quota is held."
  defp unknown_authority_reason(_reason, false), do: "CODEOWNER authority is unknown because owner lookup failed."

  defp path_suffix(nil), do: ""
  defp path_suffix(path), do: " matching #{path}"

  # Anonymous reads still spend a GitHub budget — the 60/hr unauthenticated IP
  # allowance — so they go through `Transport` like every other call rather than
  # straight to `Req`. They are tagged `anonymous: true` so `Quota` meters them
  # against their own window instead of polluting the authenticated one.
  defp default_request_fun(%{method: :get, url: url, token: token}) do
    request = %{method: :get, url: url, token: token}

    request =
      if is_binary(token) and token != "",
        do: request,
        else: Map.put(request, :anonymous, true)

    Transport.default_request_fun(request)
  end
end
