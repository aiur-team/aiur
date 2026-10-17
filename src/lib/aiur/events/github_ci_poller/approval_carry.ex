defmodule Aiur.Events.GithubCIPoller.ApprovalCarry do
  @moduledoc """
  Classifies a push made after a PR was approved (#4668).

  The PR's contribution diff at the approved head (`merge-base(approved, base)..approved`)
  is compared with the one at the new head. The approval carries only when both
  are identical: the same files and the same hunks, context included, each at the
  same place once the base's own edits above it are allowed for. Any other
  difference, conflict resolution included, does not carry.

  A carried approval also needs the PR body `Tested head` to name the new head.
  Anything unreadable or truncated fails closed to `:changed`.
  """

  alias Aiur.Config
  alias Aiur.GitHub.Transport

  @type hunk :: %{file: String.t(), side: :approved | :current, header: String.t(), lines: [String.t()]}
  @type verdict :: :carried | {:changed, %{reason: term(), hunks: [hunk()]}}

  @spec classify(String.t(), String.t(), integer(), keyword()) :: verdict()
  def classify(approved_head, head, pr_number, opts \\ []) do
    with {:ok, token} <- Transport.require_token(opts),
         {:ok, {owner, repo}} <- Transport.parse_repo() do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      base = URI.encode(Config.base_branch(opts), &URI.char_unreserved?/1)

      fetch = fn path ->
        Transport.fetch_json_map(request_fun, token, "#{Transport.base_url()}/repos/#{owner}/#{repo}/#{path}", caller: "approval_carry")
      end

      with {:ok, pr} <- fetch.("pulls/#{pr_number}"),
           {:ok, approved} <- fetch.("compare/#{base}...#{approved_head}"),
           {:ok, current} <- fetch.("compare/#{base}...#{head}"),
           {:ok, approved_base} <- merge_base(approved),
           {:ok, current_base} <- merge_base(current),
           {:ok, main} <- base_changes(fetch, approved_base, current_base) do
        classify_diffs(approved, current, main, Map.get(pr, "body") || "", head)
      else
        {:error, reason} -> {:changed, %{reason: {:unavailable, reason}, hunks: []}}
      end
    else
      {:error, reason} -> {:changed, %{reason: {:unavailable, reason}, hunks: []}}
    end
  end

  defp base_changes(_fetch, same, same), do: {:ok, %{"files" => []}}

  defp base_changes(fetch, approved_base, current_base) do
    case fetch.("compare/#{approved_base}...#{current_base}") do
      {:ok, %{"status" => "ahead"} = comparison} -> {:ok, comparison}
      {:ok, _diverged} -> {:error, :base_not_advanced}
      {:error, _reason} = error -> error
    end
  end

  defp merge_base(%{"merge_base_commit" => %{"sha" => sha}}) when is_binary(sha) and sha != "", do: {:ok, sha}
  defp merge_base(_comparison), do: {:error, :merge_base_unavailable}

  @doc """
  Pure classification over three GitHub compare bodies: the approved
  contribution, the current contribution, and the base's changes between the
  two merge bases.
  """
  @spec classify_diffs(map(), map(), map(), String.t(), String.t()) :: verdict()
  def classify_diffs(approved, current, main, body, head) do
    with {:ok, approved_files} <- files(approved),
         {:ok, current_files} <- files(current),
         {:ok, main_files} <- files(main) do
      paths = Map.keys(approved_files) ++ Map.keys(current_files)

      differing =
        paths
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.flat_map(&compare_file(&1, approved_files[&1], current_files[&1], main_files[&1]))

      cond do
        differing != [] -> {:changed, %{reason: :contribution_changed, hunks: differing}}
        not Regex.match?(~r/(?m)^Tested head: #{Regex.escape(head)}\s*$/, body) -> {:changed, %{reason: :tested_head_stale, hunks: []}}
        true -> :carried
      end
    else
      :error -> {:changed, %{reason: {:unavailable, :comparison_incomplete}, hunks: []}}
    end
  end

  # A file without a readable patch can still be equal by blob sha; any other
  # unreadable file makes the comparison incomplete.
  defp files(%{"files" => files}) when is_list(files) and length(files) < 300 do
    Enum.reduce_while(files, {:ok, %{}}, fn file, {:ok, acc} ->
      case parse_file(file) do
        {:ok, filename, parsed} -> {:cont, {:ok, Map.put(acc, filename, parsed)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp files(_comparison), do: :error

  defp parse_file(%{"filename" => filename} = file) when is_binary(filename) and filename != "" do
    meta = {Map.get(file, "previous_filename"), Map.get(file, "sha")}

    case Map.get(file, "patch") do
      patch when is_binary(patch) ->
        case hunks(patch) do
          {:ok, hunks} -> {:ok, filename, %{meta: meta, hunks: hunks}}
          :error -> :error
        end

      nil ->
        {:ok, filename, %{meta: meta, hunks: :unreadable}}
    end
  end

  defp parse_file(_file), do: :error

  defp hunks(patch) do
    patch
    |> String.split("\n")
    |> Enum.reduce_while({:ok, []}, fn
      "@@ " <> _ = line, {:ok, acc} ->
        case Regex.run(~r/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/, line) do
          [_ | captures] ->
            [old_start, old_count, new_start, new_count] = Enum.map(captures ++ List.duplicate("", 4 - length(captures)), &count/1)
            {:cont, {:ok, [%{header: line, old: {old_start, old_count}, new: {new_start, new_count}, lines: [], body: []} | acc]}}

          nil ->
            {:halt, :error}
        end

      <<sign, _::binary>> = line, {:ok, [hunk | rest]} when sign in [?+, ?-] ->
        {:cont, {:ok, [%{hunk | lines: [line | hunk.lines], body: [line | hunk.body]} | rest]}}

      context, {:ok, [hunk | rest]} ->
        {:cont, {:ok, [%{hunk | body: [context | hunk.body]} | rest]}}

      _preamble, acc ->
        {:cont, acc}
    end)
    |> case do
      {:ok, hunks} -> {:ok, hunks |> Enum.map(&%{&1 | lines: Enum.reverse(&1.lines), body: Enum.reverse(&1.body)}) |> Enum.reverse()}
      :error -> :error
    end
  end

  defp count(""), do: 1
  defp count(value), do: String.to_integer(value)

  defp compare_file(_path, same, same, nil), do: []

  defp compare_file(path, approved, current, main) do
    if Enum.any?([approved, current, main], &unreadable?/1) or renamed_differently?(approved, current) do
      [%{file: path, side: :current, header: "(no readable patch or renamed differently)", lines: []}]
    else
      {approved_only, current_only} = unmatched(hunks_of(approved), hunks_of(current), hunks_of(main))

      Enum.map(approved_only, &%{file: path, side: :approved, header: &1.header, lines: &1.lines}) ++
        Enum.map(current_only, &%{file: path, side: :current, header: &1.header, lines: &1.lines})
    end
  end

  defp renamed_differently?(%{meta: {previous, _sha}}, %{meta: {current_previous, _current_sha}}), do: previous != current_previous
  defp renamed_differently?(_approved, _current), do: false

  defp unreadable?(%{hunks: :unreadable}), do: true
  defp unreadable?(_file), do: false

  defp hunks_of(nil), do: []
  defp hunks_of(%{hunks: hunks}), do: hunks

  # Each current hunk consumes at most one approved hunk with the same lines and context at the same
  # place, once the base's own edits above it are allowed for.
  defp unmatched(approved, current, main_hunks) do
    Enum.reduce(current, {approved, []}, fn hunk, {remaining, extra} ->
      case Enum.find_index(remaining, &(&1.body == hunk.body and shifted(&1.old, main_hunks) == elem(hunk.old, 0))) do
        nil -> {remaining, [hunk | extra]}
        index -> {List.delete_at(remaining, index), extra}
      end
    end)
    |> then(fn {approved_only, current_only} -> {approved_only, Enum.reverse(current_only)} end)
  end

  # Where an old-base hunk starts in the new base; a hunk the base touched has no single position.
  defp shifted({start, length}, main_hunks) do
    Enum.reduce_while(main_hunks, start, fn %{old: {main_start, main_length}, new: {_new_start, new_length}}, position ->
      cond do
        main_start + max(main_length, 1) <= start -> {:cont, position + new_length - main_length}
        start + max(length, 1) <= main_start -> {:cont, position}
        true -> {:halt, :conflict}
      end
    end)
  end
end
