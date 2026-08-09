defmodule Aiur.Codeowners do
  @moduledoc """
  Reads GitHub CODEOWNERS files and classifies comment authors.
  """

  alias Aiur.GitHub
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
  this returns an empty list; use `authoritative?/2` when the compatibility
  fallback matters.
  """
  @spec owners_for_path(String.t(), keyword()) :: [String.t()]
  def owners_for_path(path, opts \\ []) when is_binary(path) do
    path
    |> ownership_for_path(opts)
    |> Map.fetch!(:owners)
  end

  @doc """
  Returns usernames responsible for any changed path in a pull request.

  Pass `changed_paths: [...]` to avoid a GitHub API call, or pass a PR number
  with repository configuration available.
  """
  @spec owners_for_pr(String.t() | integer() | [String.t()], keyword()) :: [String.t()]
  def owners_for_pr(pr_or_paths, opts \\ []) do
    cond do
      is_list(pr_or_paths) ->
        pr_or_paths
        |> ownership_for_paths(opts)
        |> Map.fetch!(:owners)

      is_binary(pr_or_paths) or is_integer(pr_or_paths) ->
        case Keyword.get(opts, :changed_paths) || fetch_pr_changed_paths(pr_or_paths, opts) do
          {:error, _reason} -> []
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
  @spec authoritative?(String.t() | nil, ownership_context() | [String.t()] | keyword()) :: boolean()
  def authoritative?(commenter, _context) when not is_binary(commenter), do: false

  def authoritative?(commenter, context) when is_map(context) do
    cond do
      agent_login?(commenter, Map.get(context, :agent_logins, [])) ->
        false

      Map.get(context, :codeowners_present) == false ->
        true

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
  @spec ownership_for_path(String.t(), keyword()) :: ownership_context()
  def ownership_for_path(path, opts \\ []) when is_binary(path) do
    codeowners = read_codeowners(opts)

    if codeowners.present? do
      entries =
        codeowners.rules
        |> matching_rule(path)
        |> entries_for_rule(path, opts)

      %{codeowners_present: true, owners: usernames(entries), entries: entries}
    else
      %{codeowners_present: false, owners: [], entries: []}
    end
  end

  @doc """
  Returns ownership metadata for multiple paths.
  """
  @spec ownership_for_paths([String.t()], keyword()) :: ownership_context()
  def ownership_for_paths(paths, opts \\ []) when is_list(paths) do
    codeowners = read_codeowners(opts)

    if codeowners.present? do
      entries =
        paths
        |> Enum.flat_map(fn path ->
          codeowners.rules
          |> matching_rule(path)
          |> entries_for_rule(path, opts)
        end)
        |> uniq_entries()

      %{codeowners_present: true, owners: usernames(entries), entries: entries}
    else
      %{codeowners_present: false, owners: [], entries: []}
    end
  end

  @doc """
  Returns ownership metadata for all owners in the active CODEOWNERS file.
  """
  @spec repo_ownership(keyword()) :: ownership_context()
  def repo_ownership(opts \\ []) do
    codeowners = read_codeowners(opts)

    if codeowners.present? do
      entries =
        codeowners.rules
        |> Enum.flat_map(&entries_for_rule(&1, nil, opts))
        |> uniq_entries()

      %{codeowners_present: true, owners: usernames(entries), entries: entries}
    else
      %{codeowners_present: false, owners: [], entries: []}
    end
  end

  @doc """
  Adds authoritative/advisory metadata to a comment map.
  """
  @spec classify_comment(map(), ownership_context(), keyword()) :: map()
  def classify_comment(comment, ownership_context, opts \\ []) when is_map(comment) and is_map(ownership_context) do
    author = comment_author(comment)
    context = Map.put(ownership_context, :agent_logins, Keyword.get(opts, :agent_logins, []))
    authoritative = authoritative?(author, context)

    comment
    |> Map.put(:authoritative, authoritative)
    |> Map.put(:authority_reason, authority_reason(author, context, authoritative))
    |> Map.put(:codeowners, Map.take(context, [:codeowners_present, :owners, :entries]))
  end

  defp context_from_opts(opts) do
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
        |> Map.put(:agent_logins, Keyword.get(opts, :agent_logins, []))

      paths = Keyword.get(opts, :changed_paths) ->
        paths
        |> ownership_for_paths(opts)
        |> Map.put(:agent_logins, Keyword.get(opts, :agent_logins, []))

      true ->
        opts
        |> repo_ownership()
        |> Map.put(:agent_logins, Keyword.get(opts, :agent_logins, []))
    end
  end

  defp read_codeowners(opts) do
    case file_path(opts) do
      nil -> %{present?: false, rules: []}
      full_path -> %{present?: true, rules: parse_file!(full_path)}
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

  defp entries_for_rule(nil, _path, _opts), do: []

  defp entries_for_rule(%{pattern: pattern, owners: owners}, path, opts) do
    Enum.map(owners, fn owner ->
      %{handle: owner, usernames: usernames_for_owner(owner, opts), pattern: pattern, path: path}
    end)
  end

  defp usernames_for_owner("@" <> owner = handle, opts) do
    case String.split(owner, "/", parts: 2) do
      [_user] -> [normalize_login(handle)]
      [org, team_slug] -> team_members(org, team_slug, opts)
    end
  end

  defp usernames_for_owner(owner, _opts), do: [normalize_login(owner)]

  defp team_members(org, team_slug, opts) do
    cache_key = {__MODULE__, :team_members, String.downcase(org), String.downcase(team_slug)}

    case Process.get(cache_key) do
      nil ->
        case fetch_team_members(org, team_slug, opts) do
          {:ok, members} ->
            Process.put(cache_key, members)
            members

          {:error, _reason} ->
            []
        end

      members ->
        members
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

      _ ->
        {:error, :team_members_unavailable}
    end
  end

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
    "No CODEOWNERS file found; using compatibility fallback."
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
        "No authoritative author could be determined."
    end
  end

  defp path_suffix(nil), do: ""
  defp path_suffix(path), do: " matching #{path}"

  defp default_request_fun(%{method: :get, url: url, token: token}) do
    if is_binary(token) and token != "" do
      Transport.default_request_fun(%{method: :get, url: url, token: token})
    else
      Req.get(url, headers: github_headers(nil), connect_options: [timeout: 30_000])
    end
  end

  defp github_headers(nil), do: [{"Accept", "application/vnd.github+json"}]

  defp github_headers(token) do
    [
      {"Authorization", "Bearer #{token}"},
      {"Accept", "application/vnd.github+json"},
      {"X-GitHub-Api-Version", "2022-11-28"}
    ]
  end
end
