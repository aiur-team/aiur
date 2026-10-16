defmodule Aiur.Events.GithubCIPoller.ApprovalCarry do
  @moduledoc """
  Classifies a push made after a PR was approved (#4668).

  The PR's contribution diff at the approved head (`merge-base(approved, base)..approved`)
  is compared with the one at the new head. Hunks with identical changed lines
  match regardless of position. A remaining hunk is conflict resolution only when
  it overlaps a hunk the base changed between the two merge bases; under
  `src/lib/` its changed lines must also come from the PR or from the base
  itself. A carried approval also needs the PR body `Tested head` to name the
  new head. Anything unreadable or truncated fails closed to `:changed`.
  """

  alias Aiur.Config
  alias Aiur.GitHub.Transport

  @type hunk :: %{file: String.t(), side: :approved | :current, header: String.t(), lines: [String.t()]}
  @type verdict :: {:carried, %{resolved: non_neg_integer()}} | {:changed, %{reason: term(), hunks: [hunk()]}}

  @guarded_prefix "src/lib/"

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

      {differing, resolved} =
        paths
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.reduce({[], 0}, fn path, {differing, resolved} ->
          {file_differing, file_resolved} = compare_file(path, approved_files[path], current_files[path], main_files[path])
          {differing ++ file_differing, resolved + file_resolved}
        end)

      cond do
        differing != [] -> {:changed, %{reason: :contribution_changed, hunks: differing}}
        not Regex.match?(~r/(?m)^Tested head: #{Regex.escape(head)}\s*$/, body) -> {:changed, %{reason: :tested_head_stale, hunks: []}}
        true -> {:carried, %{resolved: resolved}}
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
            {:cont, {:ok, [%{header: line, old: {old_start, old_count}, new: {new_start, new_count}, lines: []} | acc]}}

          nil ->
            {:halt, :error}
        end

      <<sign, _::binary>> = line, {:ok, [hunk | rest]} when sign in [?+, ?-] ->
        {:cont, {:ok, [%{hunk | lines: [line | hunk.lines]} | rest]}}

      _context, acc ->
        {:cont, acc}
    end)
    |> case do
      {:ok, hunks} -> {:ok, hunks |> Enum.map(&%{&1 | lines: Enum.reverse(&1.lines)}) |> Enum.reverse()}
      :error -> :error
    end
  end

  defp count(""), do: 1
  defp count(value), do: String.to_integer(value)

  defp compare_file(_path, same, same, _main), do: {[], 0}

  defp compare_file(path, approved, current, main) do
    if unreadable?(approved) or unreadable?(current) or renamed_differently?(approved, current) do
      {[%{file: path, side: :current, header: "(no readable patch or renamed differently)", lines: []}], 0}
    else
      {approved_only, current_only} = unmatched(hunks_of(approved), hunks_of(current))
      main_hunks = if main && is_list(main.hunks), do: main.hunks, else: []
      main_unreadable? = main != nil and main.hunks == :unreadable
      # A guarded resolution may only recombine lines the other side or the base already carries.
      known = %{approved: changed_text(hunks_of(current) ++ main_hunks), current: changed_text(hunks_of(approved) ++ main_hunks)}

      differing =
        Enum.map(approved_only, &Map.merge(&1, %{file: path, side: :approved})) ++
          Enum.map(current_only, &Map.merge(&1, %{file: path, side: :current}))

      unexplained =
        Enum.reject(differing, fn hunk ->
          not main_unreadable? and overlaps_main?(hunk, main_hunks) and guarded_lines_known?(path, hunk, known)
        end)

      {Enum.map(unexplained, &Map.take(&1, [:file, :side, :header, :lines])), length(differing) - length(unexplained)}
    end
  end

  defp renamed_differently?(%{meta: {previous, _sha}}, %{meta: {current_previous, _current_sha}}), do: previous != current_previous
  defp renamed_differently?(_approved, _current), do: false

  defp unreadable?(%{hunks: :unreadable}), do: true
  defp unreadable?(_file), do: false

  defp hunks_of(nil), do: []
  defp hunks_of(%{hunks: hunks}), do: hunks

  # Each current hunk consumes at most one approved hunk with the same changed lines.
  defp unmatched(approved, current) do
    Enum.reduce(current, {approved, []}, fn hunk, {remaining, extra} ->
      case Enum.find_index(remaining, &(&1.lines == hunk.lines)) do
        nil -> {remaining, [hunk | extra]}
        index -> {List.delete_at(remaining, index), extra}
      end
    end)
    |> then(fn {approved_only, current_only} -> {approved_only, Enum.reverse(current_only)} end)
  end

  # Approved hunks sit in the old base's coordinates; current hunks in the new base's.
  defp overlaps_main?(%{side: side} = hunk, main_hunks) do
    {start, length} = hunk.old

    Enum.any?(main_hunks, fn main_hunk ->
      {main_start, main_length} = if side == :approved, do: main_hunk.old, else: main_hunk.new
      start < main_start + max(main_length, 1) and main_start < start + max(length, 1)
    end)
  end

  defp guarded_lines_known?(@guarded_prefix <> _rest, hunk, known), do: Enum.all?(hunk.lines, &MapSet.member?(Map.fetch!(known, hunk.side), strip(&1)))
  defp guarded_lines_known?(_path, _hunk, _known), do: true

  defp changed_text(hunks), do: hunks |> Enum.flat_map(& &1.lines) |> MapSet.new(&strip/1)

  defp strip(<<_sign, rest::binary>>), do: rest
end
