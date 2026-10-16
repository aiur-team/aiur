defmodule Aiur.LandingWatch.QuarantinePR do
  @moduledoc "Opens a reviewable one-line PR for a repeatedly failing test."

  alias Aiur.Config.TrackerSettings
  alias Aiur.GitHub.{Errors, Transport}

  @branch_prefix "aiur/quarantine/"

  @spec open(map(), pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def open(%{identity: identity, observations: observations}, ticket, opts) when is_binary(identity) and is_list(observations) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts),
         base <- Keyword.get_lazy(opts, :base_branch, &TrackerSettings.base_branch/0),
         opts <- Keyword.put(opts, :base_branch, base),
         {:ok, existing} <- list_contents(owner, repo, token, base, opts),
         {:ok, entry} <- entry(identity, ticket, existing),
         {:ok, branch} <- branch_name(identity, base),
         :ok <- publish_list_file(owner, repo, token, base, branch, entry, opts),
         {:ok, pr} <- create_pull_request(owner, repo, token, branch, ticket, observations, opts) do
      {:ok, pr}
    else
      {:error, :already_quarantined} -> {:ok, :already_quarantined}
      {:error, _} = error -> error
    end
  end

  def open(_, _, _), do: {:error, :invalid_quarantine_candidate}

  defp entry(identity, ticket, contents) do
    case String.split(identity, " :: ", parts: 2) do
      [module, name] ->
        line = Enum.join([module, name, "##{ticket}"], "\t")
        append_entry({:ok, contents}, line)

      _ ->
        {:error, :invalid_quarantine_identity}
    end
  end

  defp append_entry({:ok, contents}, line) do
    if line in String.split(contents, "\n"), do: {:error, :already_quarantined}, else: {:ok, contents |> String.trim_trailing() |> Kernel.<>("\n" <> line <> "\n")}
  end

  defp branch_name(identity, base) do
    slug = identity |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    {:ok, @branch_prefix <> slug <> "-" <> to_string(base)}
  end

  defp list_contents(owner, repo, token, base, opts) do
    case Keyword.get(opts, :quarantine_list_fun) do
      fun when is_function(fun, 0) -> fun.()
      _ -> fetch_list_contents(owner, repo, token, base, opts)
    end
  end

  defp fetch_list_contents(owner, repo, token, base, opts) do
    url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/contents/src/test/quarantine.txt?ref=#{base}"

    case request(opts).(%{method: :get, url: url, token: token, caller: "landing_watch_quarantine_contents"}) do
      {:ok, %{status: 200, body: %{"encoding" => "base64", "content" => encoded}}} ->
        case Base.decode64(String.replace(encoded, ~r/\s/, "")) do
          {:ok, contents} -> {:ok, contents}
          :error -> {:error, :invalid_quarantine_list_encoding}
        end

      {:ok, response} ->
        {:error, Errors.github_status_error(response)}

      {:error, _} = error ->
        error
    end
  end

  defp publish_list_file(owner, repo, token, base, branch, contents, opts) do
    with {:ok, ref_sha} <- create_ref(owner, repo, token, base, branch, opts),
         {:ok, base_tree} <- base_tree(owner, repo, token, base, opts),
         {:ok, blob} <- create_blob(owner, repo, contents, opts),
         {:ok, tree} <- create_tree(owner, repo, base_tree, blob, opts),
         {:ok, commit} <- create_commit(owner, repo, "Quarantine repeated flaky test", tree, [ref_sha], opts) do
      update_ref(owner, repo, branch, commit, opts)
    end
  end

  defp create_ref(owner, repo, token, base, branch, opts) do
    with {:ok, sha} <- base_sha(owner, repo, token, base, opts),
         {:ok, response} <- call(opts, :post, "repos/#{owner}/#{repo}/git/refs", %{"ref" => "refs/heads/#{branch}", "sha" => sha}),
         %{"object" => %{"sha" => sha}} <- response do
      {:ok, sha}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_quarantine_ref}
    end
  end

  defp base_sha(owner, repo, token, branch, opts) do
    case request(opts).(%{method: :get, url: "#{Transport.base_url()}/repos/#{owner}/#{repo}/git/ref/heads/#{branch}", token: token, caller: "quarantine_pr_base"}) do
      {:ok, %{status: 200, body: %{"object" => %{"sha" => sha}}}} -> {:ok, sha}
      {:ok, response} -> {:error, Errors.github_status_error(response)}
      {:error, _} = error -> error
    end
  end

  defp base_tree(owner, repo, token, branch, opts) do
    case request(opts).(%{method: :get, url: "#{Transport.base_url()}/repos/#{owner}/#{repo}/git/ref/heads/#{branch}", token: token, caller: "quarantine_pr_base_tree"}) do
      {:ok, %{status: 200, body: %{"object" => %{"sha" => commit}}}} ->
        case request(opts).(%{method: :get, url: "#{Transport.base_url()}/repos/#{owner}/#{repo}/git/commits/#{commit}", token: token, caller: "quarantine_pr_base_tree"}) do
          {:ok, %{status: 200, body: %{"tree" => %{"sha" => sha}}}} -> {:ok, sha}
          {:ok, response} -> {:error, Errors.github_status_error(response)}
          {:error, _} = error -> error
        end

      {:ok, response} ->
        {:error, Errors.github_status_error(response)}

      {:error, _} = error ->
        error
    end
  end

  defp create_blob(owner, repo, contents, opts) do
    call(opts, :post, "repos/#{owner}/#{repo}/git/blobs", %{"content" => contents, "encoding" => "utf-8"})
  end

  defp create_tree(owner, repo, base, blob, opts) do
    call(opts, :post, "repos/#{owner}/#{repo}/git/trees", %{"base_tree" => base, "tree" => [%{"path" => "src/test/quarantine.txt", "mode" => "100644", "type" => "blob", "sha" => blob["sha"]}]})
  end

  defp create_commit(owner, repo, message, tree, parents, opts) do
    call(opts, :post, "repos/#{owner}/#{repo}/git/commits", %{"message" => message, "tree" => tree["sha"], "parents" => parents})
  end

  defp update_ref(owner, repo, branch, commit, opts) do
    call(opts, :patch, "repos/#{owner}/#{repo}/git/refs/heads/#{branch}", %{"sha" => commit["sha"], "force" => false}) |> expect_ok()
  end

  defp create_pull_request(owner, repo, _token, branch, ticket, observations, opts) do
    runs = Enum.map_join(observations, "\n", &"- #{&1.run_url}")
    body = "Adds the repeated flaky test to the quarantine list.\n\nRefs ##{ticket}\n\nObserved failures in independent PR runs:\n#{runs}"

    call(opts, :post, "repos/#{owner}/#{repo}/pulls", %{
      "title" => "Quarantine repeated flaky test",
      "head" => branch,
      "base" => Keyword.get_lazy(opts, :base_branch, &TrackerSettings.base_branch/0),
      "body" => body
    })
  end

  defp call(opts, method, path, body) do
    case request(opts).(%{method: method, url: "#{Transport.base_url()}/#{path}", token: elem(Transport.require_token(opts), 1), caller: "landing_watch_quarantine_pr", body: body}) do
      {:ok, %{status: status, body: response}} when status in 200..201 and is_map(response) -> {:ok, response}
      {:ok, response} -> {:error, Errors.github_status_error(response)}
      {:error, _} = error -> error
    end
  end

  defp expect_ok({:ok, _}), do: :ok
  defp expect_ok(error), do: error
  defp request(opts), do: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
end
