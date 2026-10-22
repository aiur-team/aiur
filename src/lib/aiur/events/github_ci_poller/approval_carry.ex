defmodule Aiur.Events.GithubCIPoller.ApprovalCarry do
  @moduledoc """
  Classifies a push made after a PR was approved (#4668).

  The PR's contribution diff at the approved head (`merge-base(approved, base)..approved`)
  is compared with the one at the new head. The approval carries only when each
  changed hunk has the same changed lines and surviving context in both
  comparisons. Hunk line numbers may move when the base changes; context lines
  changed by the base are ignored.
  Any other difference, conflict resolution included, does not carry.

  A carried approval also needs the PR body `Tested head` to name the new head.
  Anything unreadable or truncated fails closed to `:changed`.
  """

  alias Aiur.Config
  alias Aiur.GitHub.Transport

  @type hunk :: %{file: String.t(), side: :approved | :current, header: String.t(), lines: [String.t()]}
  @type verdict :: :carried | {:changed, %{reason: term(), hunks: [hunk()]}}

  @spec classify(String.t(), String.t(), integer(), keyword()) :: verdict()
  def classify(approved_head, head, pr_number, opts \\ []) do
    case contribution_comparison(approved_head, head, pr_number, opts) do
      {:ok, approved, current, main, body} ->
        classify_approved_contribution(approved, current, main, body, head)

      {:error, reason} ->
        {:changed, %{reason: {:unavailable, reason}, hunks: []}}
    end
  end

  defp classify_approved_contribution(approved, current, main, body, head) do
    case classify_contribution_diffs(approved, current, main) do
      :identical ->
        if Regex.match?(~r/(?m)^Tested head: #{Regex.escape(head)}\s*$/, body), do: :carried, else: {:changed, %{reason: :tested_head_stale, hunks: []}}

      {:changed, _} = changed ->
        changed
    end
  end

  @doc "Classifies whether the PR contribution stayed identical between two heads, without checking body evidence."
  @spec classify_contribution(String.t(), String.t(), integer(), keyword()) :: :identical | {:changed, map()}
  def classify_contribution(approved_head, head, pr_number, opts \\ []) do
    case contribution_comparison(approved_head, head, pr_number, opts) do
      {:ok, approved, current, main, _body} -> classify_contribution_diffs(approved, current, main)
      {:error, reason} -> {:changed, %{reason: {:unavailable, reason}, hunks: []}}
    end
  end

  defp contribution_comparison(approved_head, head, pr_number, opts) do
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
        {:ok, approved, current, main, Map.get(pr, "body") || ""}
      else
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
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
    case classify_contribution_diffs(approved, current, main) do
      :identical ->
        if Regex.match?(~r/(?m)^Tested head: #{Regex.escape(head)}\s*$/, body), do: :carried, else: {:changed, %{reason: :tested_head_stale, hunks: []}}

      {:changed, _} = changed ->
        changed
    end
  end

  @doc "Pure comparison of the PR contribution changes at the approved and current heads."
  @spec classify_contribution_diffs(map(), map(), map()) :: :identical | {:changed, map()}
  def classify_contribution_diffs(approved, current, main) do
    with {:ok, approved_files} <- files(approved),
         {:ok, current_files} <- files(current),
         {:ok, main_files} <- files(main) do
      paths = Map.keys(approved_files) ++ Map.keys(current_files)

      differing =
        paths
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.flat_map(&compare_file(&1, approved_files[&1], current_files[&1], main_files[&1]))

      if differing != [], do: {:changed, %{reason: :contribution_changed, hunks: differing}}, else: :identical
    else
      :error -> {:changed, %{reason: {:unavailable, :comparison_incomplete}, hunks: []}}
    end
  end

  # GitHub's compare API stops listing files at 300 and sets no truncation flag, so
  # only a comparison built from local git (`"complete" => true`) may list more.
  defp files(%{"files" => files, "complete" => true}) when is_list(files), do: parse_files(files)
  defp files(%{"files" => files}) when is_list(files) and length(files) < 300, do: parse_files(files)
  defp files(_comparison), do: :error

  # A file without a readable patch can still be equal by blob sha; any other
  # unreadable file makes the comparison incomplete.
  defp parse_files(files) do
    Enum.reduce_while(files, {:ok, %{}}, fn file, {:ok, acc} ->
      case parse_file(file) do
        {:ok, filename, parsed} -> {:cont, {:ok, Map.put(acc, filename, parsed)}}
        :error -> {:halt, :error}
      end
    end)
  end

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
      compare_changed_lines(path, approved, current, main)
    end
  end

  defp compare_changed_lines(path, approved, current, main) do
    base_edits = changed_positions(main)

    if same_hunks?(hunks_of(approved), hunks_of(current), base_edits) do
      []
    else
      {approved_only, current_only} = unmatched_hunks(hunks_of(approved), hunks_of(current), base_edits)
      changed_contribution_hunks(path, approved, current, approved_only, current_only)
    end
  end

  defp changed_contribution_hunks(path, approved, current, [], []),
    do: contribution_hunks(path, :approved, approved) ++ contribution_hunks(path, :current, current)

  defp changed_contribution_hunks(path, _approved, _current, approved_only, current_only),
    do:
      contribution_hunks(path, :approved, %{hunks: approved_only}) ++
        contribution_hunks(path, :current, %{hunks: current_only})

  defp renamed_differently?(%{meta: {previous, _sha}}, %{meta: {current_previous, _current_sha}}), do: previous != current_previous
  defp renamed_differently?(_approved, _current), do: false

  defp unreadable?(%{hunks: :unreadable}), do: true
  defp unreadable?(_file), do: false

  defp hunks_of(nil), do: []
  defp hunks_of(%{hunks: hunks}), do: hunks

  # Context edits from the base can shift or shorten a hunk without changing
  # where the PR contribution sits relative to the surviving source.
  defp changed_positions(nil), do: %{removed: MapSet.new(), added: MapSet.new()}

  defp changed_positions(%{hunks: hunks}) do
    Enum.reduce(hunks, %{removed: MapSet.new(), added: MapSet.new()}, &add_hunk_positions/2)
  end

  defp add_hunk_positions(hunk, edits) do
    {old_start, _old_count} = hunk.old
    {new_start, _new_count} = hunk.new

    {_old, _new, edits} =
      Enum.reduce(hunk.body, {old_start, new_start, edits}, fn
        <<" ", _::binary>>, {old, new, acc} -> {old + 1, new + 1, acc}
        <<"-", _::binary>>, {old, new, acc} -> {old + 1, new, update_in(acc.removed, &MapSet.put(&1, old))}
        <<"+", _::binary>>, {old, new, acc} -> {old, new + 1, update_in(acc.added, &MapSet.put(&1, new))}
        _marker, positions -> positions
      end)

    edits
  end

  defp same_hunks?(approved, current, base_edits) do
    {approved_only, current_only} = unmatched_hunks(approved, current, base_edits)
    approved_only == [] and current_only == []
  end

  defp unmatched_hunks(approved, current, base_edits) do
    Enum.reduce(current, {approved, []}, fn hunk, {remaining, extra} ->
      signature = hunk_signature(hunk, base_edits.added, :current)

      case Enum.find_index(remaining, &(hunk_signature(&1, base_edits.removed, :approved) == signature)) do
        nil -> {remaining, [hunk | extra]}
        index -> {List.delete_at(remaining, index), extra}
      end
    end)
    |> then(fn {approved_only, current_only} -> {approved_only, Enum.reverse(current_only)} end)
  end

  defp hunk_signature(hunk, changed_positions, side) do
    {old_start, _old_count} = hunk.old
    {new_start, _new_count} = hunk.new

    {body, _old, _new} =
      Enum.reduce(hunk.body, {[], old_start, new_start}, fn line, {kept, old, new} ->
        keep? = not base_context_line?(line, side, old, new, changed_positions)

        {if(keep?, do: [line | kept], else: kept), old_position(line, old), new_position(line, new)}
      end)

    {hunk.lines, Enum.reverse(body)}
  end

  defp base_context_line?(<<" ", _::binary>>, :approved, old, _new, changed_positions),
    do: MapSet.member?(changed_positions, old)

  defp base_context_line?(<<" ", _::binary>>, :current, old, _new, changed_positions),
    do: MapSet.member?(changed_positions, old)

  defp base_context_line?(_line, _side, _old, _new, _changed_positions), do: false

  defp old_position(<<sign, _::binary>>, old) when sign in [?-, ?\s], do: old + 1
  defp old_position(_line, old), do: old

  defp new_position(<<sign, _::binary>>, new) when sign in [?+, ?\s], do: new + 1
  defp new_position(_line, new), do: new

  defp contribution_hunks(path, side, file) do
    file
    |> hunks_of()
    |> Enum.map(&%{file: path, side: side, header: &1.header, lines: &1.lines})
  end
end
