defmodule Aiur.PrMerge.Facts do
  @moduledoc false
  alias Aiur.PrMerge.{Checks, Client, Rules}

  @spec observe(function(), map(), pos_integer()) :: {:ok, map()} | {:error, String.t()}
  def observe(api, settings, number) do
    with {:ok, raw} <- api.("get", "repos/#{settings.tracker.github.repo}/pulls/#{number}", nil),
         {:ok, pr} <- normalize(raw, number),
         true <- pr.base == settings.tracker.base_branch or {:error, "PR base differs from tracker.base_branch"} do
      {:ok, pr}
    end
  end

  @spec read(function(), map(), pos_integer(), map()) :: {:ok, map()} | {:error, String.t()}
  def read(api, settings, number, user) do
    repo = settings.tracker.github.repo

    with {:ok, raw} <- api.("get", "repos/#{repo}/pulls/#{number}", nil),
         {:ok, pr} <- normalize(raw, number),
         true <- pr.base == settings.tracker.base_branch or {:error, "PR base differs from tracker.base_branch"},
         {:ok, checks} <- Checks.read(api, repo, number, pr.head),
         {:ok, rules} <- Rules.read(api, repo, pr.base, user),
         {:ok, files} <- Client.pages(api, "repos/#{repo}/pulls/#{number}/files"),
         true <- length(files) == raw["changed_files"] or {:error, "incomplete changed paths"},
         {:ok, labels} <- ticket_labels(api, checks.tickets),
         {:ok, %{"object" => %{"sha" => base_sha}}} <- api.("get", "repos/#{repo}/git/ref/heads/#{URI.encode(pr.base, &URI.char_unreserved?/1)}", nil) do
      paths = Enum.flat_map(files, &Enum.reject([&1["filename"], &1["previous_filename"]], fn value -> value == nil end))
      facts = pr |> Map.merge(Checks.classify(checks.checks)) |> Map.merge(rules)

      {:ok,
       Map.merge(facts, %{
         approved: checks.approved,
         changes_requested: checks.changes_requested,
         operator_id: user["id"],
         full_ci: Aiur.MergePolicy.requires_full_ci?(labels ++ pr.labels, paths, settings.merge_policy),
         base_sha: base_sha
       })}
    else
      {:error, _reason} = error -> error
      _ -> {:error, "invalid PR facts"}
    end
  end

  defp normalize(raw, number) do
    case raw do
      %{"head" => %{"sha" => head}, "base" => %{"ref" => base}, "draft" => draft, "state" => state, "title" => title, "body" => body, "labels" => labels}
      when is_binary(head) and is_binary(base) and is_boolean(draft) and is_binary(title) and is_list(labels) ->
        {:ok,
         %{
           number: number,
           node_id: raw["node_id"],
           author_id: get_in(raw, ["user", "id"]),
           merged: raw["merged"] == true,
           merge_commit_sha: raw["merge_commit_sha"],
           merged_by: get_in(raw, ["merged_by", "login"]),
           merged_at: raw["merged_at"],
           base_sha: get_in(raw, ["base", "sha"]),
           head: head,
           base: base,
           draft: draft,
           state: String.upcase(state),
           title: title,
           body: to_string(body || ""),
           labels: Enum.map(labels, & &1["name"]),
           conflict: raw["mergeable"] == false
         }}

      _ ->
        {:error, "invalid PR observation"}
    end
  end

  defp ticket_labels(api, tickets) do
    Enum.reduce_while(tickets, {:ok, []}, fn ticket, {:ok, acc} ->
      repo = ticket["repository"]["nameWithOwner"]

      case api.("get", "repos/#{repo}/issues/#{ticket["number"]}", nil) do
        {:ok, %{"labels" => labels}} when is_list(labels) -> {:cont, {:ok, acc ++ Enum.map(labels, & &1["name"])}}
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, "invalid linked ticket labels"}}
      end
    end)
  end
end
