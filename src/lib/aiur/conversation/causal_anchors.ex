defmodule Aiur.Conversation.CausalAnchors do
  @moduledoc false

  @rules %{
    "push" => {~r/(^|[;&|(]\s*|\s)git\s+push\b/, :push},
    "pr_opened" => {~r/\bgh\s+pr\s+create\b/, :opened},
    "pr_merged" => {~r/\bgh\s+pr\s+merge\b/, :merged}
  }

  @spec command(map(), [map()]) :: map() | nil
  def command(event, entries) do
    with {regex, key} <- @rules[event.kind],
         %DateTime{} = time <- instant(event.observed_at) do
      results = Map.new(for entry <- entries, entry.kind == "tool_result", id = field(entry.refs, :tool_call_id), is_binary(id), do: {{entry.session_seq, id}, entry})

      entries
      |> Enum.filter(fn entry ->
        entry.kind == "command" && in_window?(entry.observed_at, time) &&
          Regex.match?(regex, entry.body) && matches?(key, event, entry, results, time)
      end)
      |> Enum.max_by(& &1.pos, fn -> nil end)
    else
      _ -> nil
    end
  end

  defp matches?(key, event, entry, results, time) do
    case evidence(entry, results, time) do
      {:ok, output} -> key_match?(key, field(event, :payload) || event, entry.body, output)
      :none -> false
    end
  end

  defp evidence(entry, results, time) do
    case field(entry.meta, :exit_code) do
      0 -> {:ok, entry.output || ""}
      nil -> joined_result(entry, results, time)
      _ -> :none
    end
  end

  defp joined_result(entry, results, time) do
    id = field(entry.refs, :tool_call_id)
    result = if is_binary(id), do: Map.get(results, {entry.session_seq, id})

    if result && result.pos > entry.pos && field(result.meta, :success) == true &&
         in_window?(result.observed_at, time),
       do: {:ok, result.output || ""},
       else: :none
  end

  defp key_match?(:push, event, _body, output) do
    sha = field(event, :sha)
    ref = field(event, :ref)

    range? =
      is_binary(sha) && sha != "" &&
        Enum.any?(Regex.scan(~r/\b[0-9a-f]{7,40}\.\.\.?([0-9a-f]{7,40})\b/, output), fn [_, head] -> String.starts_with?(sha, head) end)

    branch? =
      is_binary(ref) &&
        Enum.any?(Regex.scan(~r/\[new branch\][^\n]*?\s+\S+\s+->\s+(\S+)/, output), fn [_, branch] -> branch == String.replace_prefix(ref, "refs/heads/", "") end)

    range? || branch?
  end

  defp key_match?(kind, event, body, output) do
    pr = field(event, :pr) || field(event, :pull_request) || %{}
    number = field(pr, :number)
    urls = Regex.scan(~r{/pull/(\d+)\b}, output)
    keys = if kind == :merged, do: urls ++ Regex.scan(~r/\bgh\s+pr\s+merge\s+#?(\d+)\b/, body), else: urls
    is_integer(number) && Enum.any?(keys, fn [_, key] -> String.to_integer(key) == number end)
  end

  defp in_window?(value, time) do
    case instant(value) do
      %DateTime{} = at -> DateTime.diff(time, at, :microsecond) in 0..600_000_000
      _ -> false
    end
  end

  defp instant(%DateTime{} = time), do: time

  defp instant(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> time
      _ -> nil
    end
  end

  defp instant(_), do: nil
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
