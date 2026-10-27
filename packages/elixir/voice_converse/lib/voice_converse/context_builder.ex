defmodule VoiceConverse.ContextBuilder do
  @moduledoc """
  Builds the redacted, reviewable context supplied when a conversation opens.

  Context is deliberately built from bounded read ports. A missing optional port is stated in
  the `gaps` block instead of being rendered as an empty value, so the assistant never mistakes
  unavailable data for an absence of work or Commands.
  """

  alias VoiceConverse.{Briefing, Config, Ports}

  @type block :: %{source: String.t(), ref: String.t(), observed_at: String.t(), text: String.t()}
  @type result :: %{text: String.t(), blocks: [block()], gaps: [String.t()], tokens: non_neg_integer()}

  @doc """
  Builds initial context for `target` from `config`'s briefing and optional command ports.

  Options: `:now` injects the observation time for deterministic callers and tests. The total
  budget comes from `config.limits.context_token_budget`; command and gap blocks are retained
  even if they alone exceed it. Tokens use the package-wide `div(byte_size(text), 4)` estimate.
  """
  @spec build(Config.t(), term(), keyword()) :: result()
  def build(%Config{} = config, target, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    descriptor = describe_target(config.briefing_source, target)
    identity = block("identity", descriptor, now, identity_text(descriptor))
    {commands, command_gaps} = command_block(config, target, descriptor, now)
    gaps = command_gaps
    gap_block = if gaps == [], do: nil, else: block("gaps", descriptor, now, "Gaps: " <> Enum.join(gaps, "; "))
    remaining = remaining_budget(config, [identity, commands, gap_block])
    {briefing, briefing_gaps} = briefing_block(config, target, descriptor, now, remaining)
    gaps = gaps ++ briefing_gaps
    gap_block = if gaps == [], do: nil, else: block("gaps", descriptor, now, "Gaps: " <> Enum.join(gaps, "; "))

    blocks = [briefing, identity, commands, gap_block] |> Enum.reject(&is_nil/1) |> redact(config.redactor)
    text = blocks |> Enum.map_join("\n\n", & &1.text)
    %{text: text, blocks: blocks, gaps: gaps, tokens: estimate(text)}
  end

  defp briefing_block(config, target, descriptor, now, budget) do
    case Ports.call_port(config.briefing_source, :brief, [target], :brief) do
      {:ok, %Briefing{} = briefing} ->
        {text, _meta} = Briefing.render(briefing, budget: min(config.limits.briefing_token_budget, budget), now: now)
        {block("briefing", descriptor, now, text), []}

      _ ->
        {nil, ["Briefing data unavailable"]}
    end
  end

  defp command_block(%Config{command_source: nil}, _target, _descriptor, _now), do: {nil, ["Command data unavailable"]}

  defp command_block(%Config{command_source: source}, target, descriptor, now) do
    case Ports.call_port(source, :open, [target], :fetch) do
      {:ok, commands} when is_list(commands) and commands != [] ->
        {block("commands", descriptor, now, Enum.map_join(commands, "\n\n", &command_text/1)), []}

      {:ok, []} ->
        {nil, []}

      _ ->
        {nil, ["Command data unavailable"]}
    end
  end

  defp identity_text(%{title: title, kind: kind}), do: "Target: #{title}\nKind: #{kind}"
  defp identity_text(descriptor), do: "Target: #{inspect(descriptor)}"

  defp command_text(command) do
    question = Map.get(command, :question, Map.get(command, "question", ""))
    options = Map.get(command, :options, Map.get(command, "options", []))
    "Command: #{question}\nOptions: #{Enum.map_join(options, "; ", &option_label/1)}"
  end

  defp option_label(%{label: label}), do: to_string(label)
  defp option_label(%{"label" => label}), do: to_string(label)
  defp option_label(label) when is_binary(label), do: label
  defp option_label(label), do: inspect(label)

  defp block(source, descriptor, now, body) do
    observed_at = DateTime.to_iso8601(now)
    ref = descriptor |> Map.get(:id, Map.get(descriptor, "id", "target")) |> to_string()
    %{source: source, ref: ref, observed_at: observed_at, text: "### #{source} (observed #{observed_at})\n#{body}"}
  end

  defp remaining_budget(config, blocks) do
    (config.limits.context_token_budget -
       (blocks |> Enum.reject(&is_nil/1) |> Enum.map(& &1.text) |> Enum.map(&estimate/1) |> Enum.sum()))
    |> max(0)
  end

  defp describe_target(source, target) do
    case source.describe_target(target) do
      %{} = descriptor -> descriptor
      _ -> fallback_descriptor()
    end
  rescue
    _error -> fallback_descriptor()
  end

  defp fallback_descriptor, do: %{id: "target", kind: "unknown", title: "Unknown target"}

  defp redact(blocks, redactor) do
    Enum.map(blocks, fn block ->
      block
      |> Map.update!(:ref, redactor)
      |> Map.update!(:text, redactor)
    end)
  end

  defp estimate(text), do: div(byte_size(text), 4)
end
