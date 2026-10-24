defmodule Aiur.LandingWatch.QuarantinePR do
  @moduledoc """
  Opens an auto-merging one-line PR that quarantines a base-failing test with expiry metadata.

  Every step is safe to repeat, so a transient GitHub error on one poll is retried on the
  next: an existing branch is moved to the new commit and an existing PR is reused.
  """

  alias Aiur.Config.TrackerSettings
  alias Aiur.GitHub.{Errors, Transport}

  @branch_prefix "aiur/quarantine/"
  @exunit_list "src/test/quarantine.txt"
  @browser_list "src/browser/quarantine.txt"

  @auto_merge """
  mutation($id: ID!) {
    enablePullRequestAutoMerge(input: {pullRequestId: $id}) { pullRequest { number } }
  }
  """

  @doc "The quarantine list for a test identity: Playwright specs (`BrowserSpec :: src/browser/tests/<spec>`) use the browser list."
  @spec list_path(String.t()) :: String.t()
  def list_path(identity),
    do: if(String.starts_with?(identity, "BrowserSpec :: "), do: @browser_list, else: @exunit_list)

  @spec open(map(), pos_integer(), keyword()) ::
          {:ok, map() | :already_quarantined} | {:error, term()}
  def open(%{identity: identity, observations: observations}, ticket, opts)
      when is_binary(identity) and is_list(observations) do
    opts = Keyword.put_new(opts, :quarantine_expires_on, Date.add(Date.utc_today(), 90))

    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts),
         base <- Keyword.get_lazy(opts, :base_branch, &TrackerSettings.base_branch/0),
         ctx <- %{
           owner: owner,
           repo: repo,
           token: token,
           base: base,
           path: list_path(identity),
           opts: opts
         },
         {:ok, existing} <- list_contents(ctx),
         expires <- expiry(ctx, opts),
         {:ok, contents} <- entry(identity, ticket, existing, expires),
         {:ok, branch} <- branch_name(identity, base),
         {:ok, base_sha, commit_sha} <- reuse_or_publish(ctx, branch, contents, identity),
         {:ok, pr} <-
           pull_request(ctx, branch, identity, ticket, observations, base_sha, commit_sha),
         :ok <- enable_auto_merge(ctx, pr) do
      {:ok, pr}
    else
      {:error, :already_quarantined} -> {:ok, :already_quarantined}
      {:error, _} = error -> error
    end
  end

  def open(_, _, _), do: {:error, :invalid_quarantine_candidate}

  @spec already_quarantined?(String.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def already_quarantined?(identity, opts) when is_binary(identity) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts),
         base <- Keyword.get_lazy(opts, :base_branch, &TrackerSettings.base_branch/0),
         ctx <- %{owner: owner, repo: repo, token: token, base: base, path: list_path(identity), opts: opts},
         {:ok, contents} <- list_contents(ctx) do
      {:ok, listed?(contents, identity)}
    end
  end

  def already_quarantined?(_, _), do: {:error, :invalid_quarantine_identity}

  defp entry(identity, ticket, contents, expires) do
    case String.split(identity, " :: ", parts: 2) do
      [module, name] ->
        fields =
          [module, name, "##{ticket}"] ++ if(expires, do: [Date.to_iso8601(expires)], else: [])

        line = Enum.join(fields, "\t")

        if listed?(contents, identity),
          do: {:error, :already_quarantined},
          else: {:ok, String.trim_trailing(contents) <> "\n" <> line <> "\n"}

      _ ->
        {:error, :invalid_quarantine_identity}
    end
  end

  defp expiry(%{path: @browser_list}, _opts), do: nil
  defp expiry(_ctx, opts), do: Keyword.fetch!(opts, :quarantine_expires_on)

  defp listed?(contents, identity) do
    [module, name] = String.split(identity, " :: ", parts: 2)

    contents
    |> String.split("\n")
    |> Enum.any?(&String.starts_with?(&1, module <> "\t" <> name <> "\t"))
  end

  # An earlier attempt that already committed the entry is reused, so a retry after an
  # auto-merge or PR error never writes a new head (which would restart the PR's CI).
  defp reuse_or_publish(ctx, branch, contents, identity) do
    case get(ctx, "git/ref/heads/#{branch}", "landing_watch_quarantine_branch") do
      {:ok, %{"object" => %{"sha" => head}}} ->
        reuse_if_listed(ctx, branch, head, contents, identity)

      {:error, {:github, _, %{status: 404}}} ->
        publish_list_file(ctx, branch, contents, identity)

      {:ok, _} ->
        {:error, :invalid_quarantine_git_response}

      {:error, _} = error ->
        error
    end
  end

  defp reuse_if_listed(ctx, branch, head, contents, identity) do
    case fetch_list_contents(%{ctx | base: branch}) do
      {:ok, existing} ->
        if listed?(existing, identity),
          do: reuse(ctx, head),
          else: publish_list_file(ctx, branch, contents, identity)

      {:error, _} = error ->
        error
    end
  end

  defp reuse(ctx, head) do
    case get(ctx, "git/ref/heads/#{ctx.base}", "quarantine_pr_base") do
      {:ok, %{"object" => %{"sha" => base_sha}}} -> {:ok, base_sha, head}
      {:ok, _} -> {:error, :invalid_quarantine_git_response}
      {:error, _} = error -> error
    end
  end

  defp branch_name(identity, base) do
    slug =
      identity
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    {:ok, @branch_prefix <> slug <> "-" <> to_string(base)}
  end

  defp list_contents(ctx) do
    case Keyword.get(ctx.opts, :quarantine_list_fun) do
      fun when is_function(fun, 0) -> fun.()
      _ -> fetch_list_contents(ctx)
    end
  end

  defp fetch_list_contents(ctx) do
    case get(ctx, "contents/#{ctx.path}?ref=#{ctx.base}", "landing_watch_quarantine_contents") do
      {:ok, %{"encoding" => "base64", "content" => encoded}} ->
        case Base.decode64(String.replace(encoded, ~r/\s/, "")) do
          {:ok, contents} -> {:ok, contents}
          :error -> {:error, :invalid_quarantine_list_encoding}
        end

      {:ok, _} ->
        {:error, :invalid_quarantine_list}

      # The browser list is created by its first entry.
      {:error, {:github, _, %{status: 404}}} ->
        {:ok, "# BrowserSpec, spec path (as the failure annotation names it), and tracking ticket. Tabs delimit fields.\n"}

      {:error, _} = error ->
        error
    end
  end

  defp publish_list_file(ctx, branch, contents, identity) do
    with {:ok, %{"object" => %{"sha" => base_sha}}} <-
           get(ctx, "git/ref/heads/#{ctx.base}", "quarantine_pr_base"),
         {:ok, %{"tree" => %{"sha" => base_tree}}} <-
           get(ctx, "git/commits/#{base_sha}", "quarantine_pr_base_tree"),
         {:ok, %{"sha" => blob}} <-
           write(ctx, :post, "git/blobs", %{"content" => contents, "encoding" => "utf-8"}),
         {:ok, %{"sha" => tree}} <-
           write(ctx, :post, "git/trees", %{
             "base_tree" => base_tree,
             "tree" => [
               %{"path" => ctx.path, "mode" => "100644", "type" => "blob", "sha" => blob}
             ]
           }),
         {:ok, %{"sha" => commit}} <-
           write(ctx, :post, "git/commits", %{
             "message" => "Quarantine flaky test #{identity}",
             "tree" => tree,
             "parents" => [base_sha]
           }),
         :ok <- point_branch(ctx, branch, commit) do
      {:ok, base_sha, commit}
    else
      {:ok, _unexpected} -> {:error, :invalid_quarantine_git_response}
      {:error, _} = error -> error
    end
  end

  # A branch left by an earlier, interrupted attempt is moved to the new commit.
  defp point_branch(ctx, branch, commit) do
    case write(ctx, :post, "git/refs", %{"ref" => "refs/heads/#{branch}", "sha" => commit}) do
      {:ok, _} ->
        :ok

      {:error, {:github, _, %{status: 422}}} ->
        write(ctx, :patch, "git/refs/heads/#{branch}", %{"sha" => commit, "force" => true})
        |> expect_ok()

      {:error, _} = error ->
        error
    end
  end

  defp pull_request(ctx, branch, identity, ticket, observations, base_sha, commit_sha) do
    body = %{
      "title" => "Quarantine flaky test #{identity}",
      "head" => branch,
      "base" => ctx.base,
      "body" => body(ctx, identity, ticket, observations, base_sha, commit_sha)
    }

    case write(ctx, :post, "pulls", body) do
      {:ok, pr} -> {:ok, pr}
      {:error, {:github, _, %{status: 422}}} -> existing_pull_request(ctx, branch)
      {:error, _} = error -> error
    end
  end

  defp existing_pull_request(ctx, branch) do
    query = URI.encode_query(%{head: "#{ctx.owner}:#{branch}", state: "open"})

    case get(ctx, "pulls?" <> query, "landing_watch_quarantine_pr") do
      {:ok, [pr | _]} -> {:ok, pr}
      {:ok, _} -> {:error, :quarantine_pull_request_not_found}
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec body(map(), String.t(), pos_integer(), [map()], String.t(), String.t()) :: String.t()
  def body(ctx, identity, ticket, observations, base_sha, commit_sha) do
    runs =
      observations |> Enum.map(& &1.run_url) |> Enum.uniq() |> Enum.map_join("\n", &"- #{&1}")

    checked_paths = observations |> Enum.flat_map(&Map.get(&1, :checked_paths, [])) |> Enum.uniq() |> Enum.sort()
    checked = Enum.map_join(checked_paths, "\n", &"- `#{&1}`")

    list = ctx.path
    {skip, scope} = skip_scope(identity)

    """
    Refs ##{ticket}

    #### Context

    `#{identity}` failed in base-branch CI, or in two merge groups whose PRs did not touch it, within 24 hours.

    #### TL;DR

    *Skip #{skip} in blocking CI until ##{ticket} fixes it.*

    #### Summary

    - Adds one line to `#{list}`#{expiry_description(ctx)}; blocking CI skips #{scope} and the non-blocking quarantine job still runs it nightly.
    - The landing watcher opened this PR. Failed runs:
    #{runs}

    #### Base-commit paths checked

    #{if checked == "", do: "No base-commit path check was used for these observations.", else: checked}

    #### Alternatives

    - Leave the test blocking: every failure drops approved PRs from the merge queue.

    #### Complexity routing

    - Signal: complexity:1
    - Skills used: none (automatic quarantine)
    - Rationale: one generated list entry
    - Adjustment: none

    #### Docs

    - [x] Docs not required

    ## Local tests

    Policy: none
    Tested head: #{commit_sha}
    Base: #{ctx.base} @ #{base_sha}
    Selection: a quarantine-list entry changes no code; CI checks the list format
    - `none` -> not run; the daemon generated this list change
    """
  end

  defp expiry_description(%{path: @browser_list}), do: ""
  defp expiry_description(ctx), do: " through #{Keyword.fetch!(ctx.opts, :quarantine_expires_on)}"

  # A browser entry skips every test in its spec file, so the body names the file.
  defp skip_scope("BrowserSpec :: " <> spec),
    do: {"the flaky spec file `#{spec}`", "every test in `#{spec}`"}

  defp skip_scope(_identity), do: {"one flaky test", "the test"}

  defp enable_auto_merge(ctx, %{"node_id" => id}) when is_binary(id) do
    case Transport.github_graphql(request(ctx.opts), ctx.token, @auto_merge, %{"id" => id}, caller: "landing_watch_quarantine_auto_merge") do
      {:ok, %{"data" => %{"enablePullRequestAutoMerge" => %{}}}} -> :ok
      {:ok, _} -> {:error, :quarantine_auto_merge_unconfirmed}
      {:error, _} = error -> error
    end
  end

  defp enable_auto_merge(_ctx, _pr), do: {:error, :quarantine_pull_request_missing_node_id}

  defp get(ctx, path, caller) do
    request(ctx.opts).(%{
      method: :get,
      url: "#{Transport.base_url()}/repos/#{ctx.owner}/#{ctx.repo}/#{path}",
      token: ctx.token,
      caller: caller
    })
    |> response()
  end

  defp write(ctx, method, path, body) do
    request(ctx.opts).(%{
      method: method,
      url: "#{Transport.base_url()}/repos/#{ctx.owner}/#{ctx.repo}/#{path}",
      token: ctx.token,
      caller: "landing_watch_quarantine_pr",
      body: body
    })
    |> response()
  end

  defp response({:ok, %{status: status, body: body}}) when status in 200..201, do: {:ok, body}

  defp response({:ok, %{status: _} = response}),
    do: {:error, Errors.github_status_error(response)}

  defp response({:error, _} = error), do: error

  defp expect_ok({:ok, _}), do: :ok
  defp expect_ok(error), do: error
  defp request(opts), do: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
end
