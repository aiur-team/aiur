defmodule Aiur.GitHub.HumanReviewContribution do
  # Keeps approval equivalence checks separate from the state gate: bounded
  # GitHub comparisons, commit ancestry, and patch fingerprints all fail closed.
  @moduledoc false

  @doc false
  @spec unchanged?(String.t(), String.t(), String.t(), map(), (String.t(), String.t(), pos_integer() -> {:ok, map()} | {:error, term()})) ::
          {:ok, boolean()} | {:error, term()}
  def unchanged?(approved_head, head, base_sha, current_comparison, compare_fun) do
    with {:ok, approved_comparison} <- compare_fun.(base_sha, approved_head, 100),
         {:ok, approved_merge_base} <- merge_base_sha(approved_comparison),
         {:ok, base_comparison} <- compare_fun.(approved_merge_base, base_sha, 100),
         {:ok, base_commits} <- comparison_commit_shas(base_comparison),
         {:ok, post_approval_comparison} <- compare_fun.(approved_head, head, 100),
         {:ok, true} <- only_base_merges(post_approval_comparison, approved_head, [approved_merge_base, base_sha | base_commits]),
         {:ok, approved_diff} <- compare_fun.(approved_merge_base, approved_head, 100),
         {:ok, approved_fingerprint} <- contribution_fingerprint(approved_diff),
         {:ok, current_fingerprint} <- contribution_fingerprint(current_comparison),
         contribution_paths = contribution_paths(approved_fingerprint, current_fingerprint),
         {:ok, base_hunks} <- base_hunk_offsets(base_comparison, contribution_paths) do
      {:ok, same_contribution?(approved_fingerprint, current_fingerprint, base_hunks)}
    end
  end

  defp only_base_merges(comparison, approved_head, base_commits) do
    with {:ok, commits} <- comparison_commits(comparison) do
      allow_base_merge_chain(commits, approved_head, MapSet.new(base_commits), false)
    end
  end

  defp comparison_commit_shas(comparison) do
    with {:ok, commits} <- comparison_commits(comparison) do
      {:ok, Enum.map(commits, & &1["sha"])}
    end
  end

  defp comparison_commits(%{"commits" => commits, "total_commits" => total})
       when is_list(commits) and is_integer(total) and total == length(commits) and total <= 100 do
    Enum.reduce_while(commits, {:ok, []}, fn
      %{"sha" => sha} = commit, {:ok, found} when is_binary(sha) and sha != "" -> {:cont, {:ok, [commit | found]}}
      _commit, _acc -> {:halt, {:error, :review_base_ancestry_unavailable}}
    end)
    |> case do
      {:ok, found} -> {:ok, Enum.reverse(found)}
      {:error, _reason} = error -> error
    end
  end

  defp comparison_commits(_comparison), do: {:error, :review_base_ancestry_unavailable}

  defp allow_base_merge_chain([], _feature_head, _base_commits, merged?), do: {:ok, merged?}

  defp allow_base_merge_chain([%{"sha" => sha} = commit | rest], feature_head, base_commits, merged?) do
    if MapSet.member?(base_commits, sha) do
      allow_base_merge_chain(rest, feature_head, base_commits, merged?)
    else
      allow_base_merge(commit, rest, feature_head, base_commits)
    end
  end

  defp allow_base_merge(commit, rest, feature_head, base_commits) do
    with {:ok, {merge_sha, base_parent}} <- base_merge_entry(commit, feature_head),
         true <- MapSet.member?(base_commits, base_parent) do
      allow_base_merge_chain(rest, merge_sha, base_commits, true)
    else
      _invalid -> {:ok, false}
    end
  end

  defp base_merge_entry(%{"sha" => sha, "parents" => [%{"sha" => first}, %{"sha" => second}]}, feature_head) do
    cond do
      first == feature_head -> {:ok, {sha, second}}
      second == feature_head -> {:ok, {sha, first}}
      true -> :error
    end
  end

  defp base_merge_entry(_commit, _feature_head), do: :error

  defp merge_base_sha(%{"merge_base_commit" => %{"sha" => sha}}) when is_binary(sha) and sha != "", do: {:ok, sha}
  defp merge_base_sha(_comparison), do: {:error, :review_base_ancestry_unavailable}

  defp contribution_fingerprint(%{"files" => files}) when is_list(files) and length(files) < 300 do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, fingerprints} ->
      case contribution_file_fingerprint(file) do
        {:ok, fingerprint} -> {:cont, {:ok, [fingerprint | fingerprints]}}
        :error -> {:halt, {:error, :review_base_ancestry_unavailable}}
      end
    end)
    |> case do
      {:ok, fingerprints} -> {:ok, Enum.sort(fingerprints)}
      {:error, _reason} = error -> error
    end
  end

  defp contribution_fingerprint(_comparison), do: {:error, :review_base_ancestry_unavailable}

  defp contribution_file_fingerprint(%{"filename" => filename, "patch" => patch} = file)
       when is_binary(filename) and filename != "" and is_binary(patch) do
    previous = Map.get(file, "previous_filename")

    if is_nil(previous) or (is_binary(previous) and previous != "") do
      {changes, context, locations} = patch |> String.split("\n") |> Enum.reduce({[], [], []}, &collect_fingerprint_line/2)

      if locations == [] or :invalid in locations do
        :error
      else
        {:ok, {filename, previous, changes, context, Enum.reverse(locations)}}
      end
    else
      :error
    end
  end

  defp contribution_file_fingerprint(_file), do: :error

  defp same_contribution?(approved, current, base_hunks) when length(approved) == length(current) do
    Enum.zip(approved, current)
    |> Enum.all?(fn {approved_file, current_file} -> same_file_contribution?(approved_file, current_file, base_hunks) end)
  end

  defp same_contribution?(_approved, _current, _base_hunks), do: false

  defp same_file_contribution?({file, previous, changes, context, locations}, {current_file, current_previous, current_changes, current_context, current_locations}, base_hunks)
       when file == current_file and previous == current_previous and changes == current_changes do
    related_context?(context, current_context) and
      related_hunk_locations?(locations, current_locations, Map.get(base_hunks, file, []))
  end

  defp same_file_contribution?(_approved, _current, _base_hunks), do: false

  defp related_context?(context, current) when context == current, do: true

  defp related_context?(approved, current) do
    shared = ordered_context_anchors(approved, current)
    unmatched = length(approved) + length(current) - 2 * shared
    shared >= 2 and unmatched <= 1
  end

  defp ordered_context_anchors(approved, current) do
    Enum.reduce(approved, {current, 0}, fn line, {remaining, count} ->
      case Enum.split_while(remaining, &(&1 != line)) do
        {_skipped, [_match | rest]} -> {rest, count + 1}
        _missing -> {remaining, count}
      end
    end)
    |> elem(1)
  end

  defp related_hunk_locations?(approved, current, hunks) when length(approved) == length(current) do
    Enum.zip(approved, current)
    |> Enum.all?(fn {{old_a, new_a}, {old_b, new_b}} ->
      case base_offset_before(hunks, old_a) do
        {:ok, offset} -> abs(old_a + offset - old_b) <= 1 and abs(new_a + offset - new_b) <= 1
        :error -> false
      end
    end)
  end

  defp related_hunk_locations?(_approved, _current, _hunks), do: false

  defp contribution_paths(approved, current) do
    (approved ++ current)
    |> Enum.map(fn {filename, _previous, _changes, _context, _locations} -> filename end)
    |> MapSet.new()
  end

  defp base_hunk_offsets(%{"files" => files}, contribution_paths) when is_list(files) and length(files) < 300 do
    Enum.reduce_while(files, {:ok, %{}}, fn
      %{"filename" => filename, "patch" => patch}, {:ok, offsets} when is_binary(filename) and is_binary(patch) ->
        parse_relevant_base_file(filename, patch, offsets, contribution_paths)

      %{"filename" => filename} = file, {:ok, offsets}
      when is_binary(filename) and not is_map_key(file, "patch") ->
        if MapSet.member?(contribution_paths, filename),
          do: {:halt, {:error, :review_base_ancestry_unavailable}},
          else: {:cont, {:ok, offsets}}

      _file, _acc ->
        {:halt, {:error, :review_base_ancestry_unavailable}}
    end)
  end

  defp base_hunk_offsets(_comparison, _contribution_paths), do: {:error, :review_base_ancestry_unavailable}

  defp parse_relevant_base_file(filename, patch, offsets, contribution_paths) do
    if MapSet.member?(contribution_paths, filename) do
      case base_file_hunks(patch) do
        {:ok, hunks} -> {:cont, {:ok, Map.put(offsets, filename, hunks)}}
        :error -> {:halt, {:error, :review_base_ancestry_unavailable}}
      end
    else
      {:cont, {:ok, offsets}}
    end
  end

  defp base_file_hunks(patch) do
    patch
    |> String.split("\n")
    |> Enum.reduce_while({:ok, []}, &collect_base_hunk/2)
    |> case do
      {:ok, hunks} -> {:ok, Enum.reverse(hunks)}
      :error -> :error
    end
  end

  defp collect_base_hunk("@@ " <> line, {:ok, hunks}) do
    case Regex.run(~r/^@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@/, "@@ " <> line) do
      [_, old_start, old_count, new_start, new_count] ->
        parsed = parse_base_hunk(old_start, old_count, new_start, new_count)
        if parsed, do: {:cont, {:ok, [parsed | hunks]}}, else: {:halt, :error}

      [_, old_start, old_count, new_start] ->
        parsed = parse_base_hunk(old_start, old_count, new_start, "")
        if parsed, do: {:cont, {:ok, [parsed | hunks]}}, else: {:halt, :error}

      [_, old_start, new_start] ->
        parsed = parse_base_hunk(old_start, "", new_start, "")
        if parsed, do: {:cont, {:ok, [parsed | hunks]}}, else: {:halt, :error}

      _invalid ->
        {:halt, :error}
    end
  end

  defp collect_base_hunk(_line, acc), do: {:cont, acc}

  defp parse_base_hunk(old_start, old_count, new_start, new_count) do
    old_start = String.to_integer(old_start)
    new_start = String.to_integer(new_start)

    old_count_value = hunk_count(old_count, 1)
    new_count_value = hunk_count(new_count, 1)
    insertion_at_start? = old_start == 0 and new_start > 0 and old_count_value == 0
    deletion_at_start? = old_start > 0 and new_start == 0 and new_count_value == 0
    ordinary_hunk? = old_start > 0 and new_start > 0

    if insertion_at_start? or deletion_at_start? or ordinary_hunk? do
      {old_start, old_count_value, new_count_value}
    end
  end

  defp hunk_count("", default), do: default
  defp hunk_count(value, _default), do: String.to_integer(value)

  defp base_offset_before(hunks, feature_start) do
    Enum.reduce_while(hunks, {:ok, 0}, fn {old_start, old_count, new_count}, {:ok, offset} ->
      cond do
        old_count == 0 and old_start <= feature_start -> {:cont, {:ok, offset + new_count}}
        old_start + old_count <= feature_start -> {:cont, {:ok, offset + new_count - old_count}}
        old_start >= feature_start -> {:cont, {:ok, offset}}
        true -> {:halt, :error}
      end
    end)
  end

  defp collect_fingerprint_line("@@ " <> _hunk = line, {changes, context, locations}) do
    case Regex.run(~r/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/, line) do
      [_, old_start, new_start] -> {changes, context, [{String.to_integer(old_start), String.to_integer(new_start)} | locations]}
      _invalid -> {changes, context, [:invalid | locations]}
    end
  end

  defp collect_fingerprint_line(<<"+", _rest::binary>> = line, {changes, context, locations}), do: {[line | changes], context, locations}
  defp collect_fingerprint_line(<<"-", _rest::binary>> = line, {changes, context, locations}), do: {[line | changes], context, locations}
  defp collect_fingerprint_line(<<" ", rest::binary>>, {changes, context, locations}), do: {changes, [rest | context], locations}
  defp collect_fingerprint_line(_line, acc), do: acc
end
