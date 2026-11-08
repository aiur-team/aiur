defmodule Aiur.LandingWatch.QuarantineFixEvidence do
  @moduledoc false

  alias Aiur.Config.TrackerSettings
  alias Aiur.GitHub.{Access, Comments}
  alias Aiur.RecentMerge

  @test_list "src/test/quarantine.txt"
  @browser_list "src/browser/quarantine.txt"
  @list_paths [@test_list, @browser_list]

  @spec merged_fix?(pos_integer(), map(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def merged_fix?(ticket, %{"number" => number} = pr, opts) when is_integer(number) and number > 0 do
    with {:ok, context} <- context(@test_list, opts),
         {:ok, files} <- pull_request_files(number, context, opts),
         {:ok, targets} <- quarantine_targets(ticket, opts) do
      fix_evidence(ticket, pr, files, targets, opts)
    end
  end

  def merged_fix?(_ticket, _pr, _opts), do: {:ok, false}

  @spec closed_by_fix_pr?(pos_integer(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def closed_by_fix_pr?(ticket, opts) do
    with {:ok, context} <- context(@test_list, opts),
         {:ok, events} <- issue_timeline(context, ticket, opts) do
      Enum.reduce_while(events, {:ok, false}, &closing_pr_result(&1, &2, ticket, context, opts))
    end
  end

  defp closing_pr_result(event, {:ok, found}, ticket, context, opts) do
    case closing_pr?(event, ticket, context, opts) do
      {:ok, true} -> {:halt, {:ok, true}}
      {:ok, false} -> {:cont, {:ok, found}}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp issue_timeline(context, ticket, opts) do
    url = "#{Access.base_url()}/repos/#{context.owner}/#{context.repo}/issues/#{ticket}/timeline?per_page=100"
    Comments.fetch_repo_comment_stream(request(opts), context.token, url, [], caller: "quarantine_lift_ticket_timeline")
  end

  defp closing_pr?(%{"event" => "cross-referenced", "source" => %{"issue" => %{"number" => number, "body" => body, "pull_request" => _}}}, ticket, context, opts)
       when is_integer(number) and is_binary(body) do
    closes_ticket? = Integer.to_string(ticket) in RecentMerge.closing_issue_identifiers_in_body(body, "#{context.owner}/#{context.repo}")

    if closes_ticket? do
      with {:ok, files} <- pull_request_files(number, context, opts),
           {:ok, pr} <- pull_request_state(number, context, opts) do
        {:ok, Map.get(pr, "merged_at") not in [nil, ""] and Enum.any?(files, &meaningful_file?/1)}
      end
    else
      {:ok, false}
    end
  end

  defp closing_pr?(_event, _ticket, _context, _opts), do: {:ok, false}

  defp pull_request_state(number, context, opts) do
    url = "#{Access.base_url()}/repos/#{context.owner}/#{context.repo}/pulls/#{number}"

    case request(opts).(%{method: :get, url: url, token: context.token, caller: "quarantine_lift_pr_state"}) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, response} -> {:error, Access.github_status_error(response)}
      {:error, _} = error -> error
    end
  end

  defp pull_request_files(number, context, opts) do
    url = "#{Access.base_url()}/repos/#{context.owner}/#{context.repo}/pulls/#{number}/files?per_page=100"

    with {:ok, files} <- Comments.fetch_repo_comment_stream(request(opts), context.token, url, [], caller: "quarantine_lift_pr_files"),
         true <- length(files) < 3_000 and Enum.all?(files, &valid_pr_file?/1) do
      {:ok, files}
    else
      false -> {:error, :invalid_or_truncated_pull_request_files}
      {:error, _} = error -> error
    end
  end

  defp valid_pr_file?(%{"filename" => path}) when is_binary(path) and path != "", do: true
  defp valid_pr_file?(_), do: false

  defp quarantine_targets(ticket, opts) do
    Enum.reduce_while(@list_paths, {:ok, []}, fn path, {:ok, targets} ->
      with {:ok, context} <- context(path, opts),
           {:ok, contents, _sha} <- get_contents(context, opts) do
        rows = contents |> String.split("\n") |> Enum.flat_map(&row_targets(&1, ticket, path))
        {:cont, {:ok, targets ++ rows}}
      else
        {:error, {:github, _, %{status: 404}}} -> {:cont, {:ok, targets}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp row_targets(line, ticket, @browser_list) do
    fields = String.split(line, "\t")

    if "##{ticket}" in fields do
      case fields do
        ["BrowserSpec", spec | _] -> [%{test: spec, source: nil}]
        _ -> []
      end
    else
      []
    end
  end

  defp row_targets(line, ticket, @test_list) do
    target = "##{ticket}"

    case String.split(line, "\t") do
      [module, _name, ^target | _] ->
        case module_paths(module) do
          nil -> []
          paths -> [paths]
        end

      _ ->
        []
    end
  end

  defp module_paths("AiurWeb." <> module), do: module_paths(module, "aiur_web")
  defp module_paths("Aiur." <> module), do: module_paths(module, "aiur")
  defp module_paths(_module), do: nil

  defp module_paths(module, root) do
    test_path = "src/test/#{root}/#{Macro.underscore(module)}.exs"
    source_module = Regex.replace(~r/Test\z/, module, "")
    source_path = "src/lib/#{root}/#{Macro.underscore(source_module)}.ex"
    %{test: test_path, source: source_path}
  end

  defp fix_evidence(ticket, pr, files, targets, opts) do
    closes_ticket? = Integer.to_string(ticket) in RecentMerge.closing_issue_identifiers_in_body(Map.get(pr, "body"), Keyword.get(opts, :repository))
    meaningful = Enum.filter(files, &meaningful_file?/1)
    target_changed? = Enum.any?(targets, &targeted_fix?(&1, files))

    cond do
      target_changed? -> {:ok, true}
      closes_ticket? and meaningful != [] -> closed_ticket?(ticket, opts)
      true -> {:ok, false}
    end
  end

  defp closed_ticket?(ticket, opts) do
    with {:ok, context} <- context(@test_list, opts) do
      url = "#{Access.base_url()}/repos/#{context.owner}/#{context.repo}/issues/#{ticket}"

      case request(opts).(%{method: :get, url: url, token: context.token, caller: "quarantine_lift_ticket_state"}) do
        {:ok, %{status: 200, body: %{"state" => "closed"}}} -> {:ok, true}
        {:ok, %{status: 200, body: %{"state" => state}}} when is_binary(state) -> {:ok, false}
        {:ok, response} -> {:error, Access.github_status_error(response)}
        {:error, _} = error -> error
      end
    end
  end

  defp targeted_fix?(%{test: test, source: source}, files) do
    Enum.any?(files, fn file ->
      path = file["filename"]
      (source != nil and path == source) or (path == test and meaningful_test_change?(file))
    end)
  end

  defp meaningful_file?(%{"filename" => path} = file) when is_binary(path) do
    cond do
      path in @list_paths -> false
      test_file?(path) -> meaningful_test_change?(file)
      true -> true
    end
  end

  defp meaningful_file?(_file), do: false
  defp meaningful_test_change?(file), do: not skip_only_test_change?(file) and is_binary(file["patch"])

  defp test_file?(path) do
    String.contains?(path, "/test/") or String.ends_with?(path, ["_test.exs", ".spec.mjs", ".test.mjs"])
  end

  defp skip_only_test_change?(%{"patch" => patch}) when is_binary(patch) do
    changed =
      patch
      |> String.split("\n")
      |> Enum.filter(&(String.starts_with?(&1, "+") or String.starts_with?(&1, "-")))
      |> Enum.reject(&(String.starts_with?(&1, "+++") or String.starts_with?(&1, "---")))

    added_skip? = Enum.any?(changed, &Regex.match?(~r/^\+\s*(?:test|it|describe)\.skip\b/, &1))
    skip_declaration? = Enum.all?(changed, &Regex.match?(~r/^[+-]\s*(?:test|it|describe)(?:\.skip)?\s*\(/, &1))
    added_skip? and skip_declaration?
  end

  defp skip_only_test_change?(_file), do: false

  defp context(path, opts) do
    with {:ok, {owner, repo}} <- Access.parse_repo(),
         {:ok, token} <- Access.require_token(opts) do
      {:ok, %{path: path, owner: owner, repo: repo, token: token, base: Keyword.get_lazy(opts, :base_branch, &TrackerSettings.base_branch/0)}}
    end
  end

  defp get_contents(context, opts) do
    url = "#{Access.base_url()}/repos/#{context.owner}/#{context.repo}/contents/#{context.path}?ref=#{context.base}"

    case request(opts).(%{method: :get, url: url, token: context.token, caller: "quarantine_lift_contents"}) do
      {:ok, %{status: 200, body: %{"content" => encoded, "sha" => sha, "encoding" => "base64"}}} ->
        case Base.decode64(String.replace(encoded, ~r/\s/, "")) do
          {:ok, contents} -> {:ok, contents, sha}
          :error -> {:error, :invalid_quarantine_list_encoding}
        end

      {:ok, response} ->
        {:error, Access.github_status_error(response)}

      {:error, _} = error ->
        error
    end
  end

  defp request(opts), do: Keyword.get(opts, :request_fun, &Access.default_request_fun/1)
end
