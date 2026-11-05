defmodule Aiur.AgentSkills.Preload do
  @moduledoc """
  Maps a ticket to the skills its worker should load first.

  A worker's cold-start prompt used to carry no skill priority at all: every
  installed skill looked the same, so a pixel-art ticket started with the same
  context as a CI ticket. This module resolves which skills fit the ticket —
  from its lanes, its owning feature, its labels and its complexity — and renders
  a prompt block that inlines those skills' `SKILL.md` text while listing every
  other installed skill as a one-line name and description to load on demand.

  Merge order is the order the plan settled on: per-ticket override, label, lane,
  feature, complexity. A set is combined rather than replaced, except for the
  explicit `Skills only:` body line. Each resolved skill keeps the reason that
  selected it, so the dispatch record and `aiur agents` can answer "why did this
  worker get this skill".

  Skill text comes from the workspace after install, so the target repository's
  own skills and aiur's vendored ones both count. A name that resolves but is not
  installed is never dropped silently: it lands in `missing`, logs a warning and
  appears in the prompt block and the dispatch record.
  """

  require Logger

  alias Aiur.AgentSkills.Mapping
  alias Aiur.BuildOrder.Features
  alias Aiur.Lane

  @skill_file "SKILL.md"
  # A one-line index entry, not the full description: the point of the index is
  # to be scannable next to the preloaded text.
  @index_description_chars 140
  @fallback_install_path ".claude/skills"
  # The build-order registry read runs in the dispatch path; 100 ms is the same
  # bound TelemetryCohort uses for the same owner lookup.
  @owner_timeout_ms 100

  defmodule Skill do
    @moduledoc "One skill resolved for a ticket: where it came from and what the worker gets."

    @enforce_keys [:name, :reason]
    defstruct [:name, :reason, :description, :text, :path, bytes: 0]

    @type t :: %__MODULE__{
            name: String.t(),
            reason: String.t(),
            description: String.t() | nil,
            text: String.t() | nil,
            path: String.t() | nil,
            bytes: non_neg_integer()
          }
  end

  defstruct mapped: [], truncated: [], missing: [], index: [], lanes: [], bytes: 0, max_bytes: nil, configured?: false

  @type t :: %__MODULE__{
          mapped: [Skill.t()],
          truncated: [Skill.t()],
          missing: [Skill.t()],
          index: [%{name: String.t(), description: String.t() | nil}],
          lanes: [String.t()],
          bytes: non_neg_integer(),
          max_bytes: pos_integer() | nil,
          configured?: boolean()
        }

  @doc """
  Resolve the preload for `issue` against the skills installed in `workspace`.

  Options:

    * `:settings` — a settings struct (or `{:ok, struct}`), read from config when
      omitted. Read per call, so a config change takes effect on the next
      dispatch without a restart.
    * `:mapping` — an already-normalized `agent.skills` map.
    * `:installed` — an already-read installed-skill map.
    * `:lanes` — already-resolved lane slugs.
    * `:feature` — an already-resolved owning feature slug.

  A missing or unreadable workspace resolves to "no installed skills" rather
  than raising: prompt building must never fail because a workspace is
  mid-materialize.
  """
  @spec resolve(Aiur.Issue.t() | map(), Path.t() | nil, keyword()) :: t()
  def resolve(issue, workspace, opts \\ []) do
    settings = settings(opts)
    mapping = Keyword.get_lazy(opts, :mapping, fn -> Mapping.normalize(agent_skills(settings)) end)
    installed = Keyword.get_lazy(opts, :installed, fn -> installed_skills(workspace) end)
    lanes = Keyword.get_lazy(opts, :lanes, fn -> Lane.resolve(issue, settings) end)
    feature = Keyword.get_lazy(opts, :feature, fn -> feature_slug(issue) end)
    requests = requests(mapping, issue, lanes, feature)
    max_bytes = Mapping.max_bytes(mapping)
    {mapped, truncated, bytes} = split_by_cap(requests, installed, max_bytes)
    missing = missing(requests, installed)
    warn_missing(issue, missing)

    %__MODULE__{
      mapped: mapped,
      truncated: truncated,
      missing: missing,
      index: index_entries(installed, requests),
      lanes: lanes,
      bytes: bytes,
      max_bytes: max_bytes,
      configured?: Mapping.configured?(mapping)
    }
  end

  @doc """
  The prompt block, or `""` when the workspace has no readable skills.

  Mapped skills come first with their full `SKILL.md` text, then every other
  installed skill as a one-line index, then anything mapped but not installed.
  """
  @spec prompt_block(t()) :: String.t()
  def prompt_block(%__MODULE__{} = preload) do
    if preload.mapped == [] and preload.index == [] and preload.missing == [] do
      ""
    else
      [heading(), mapped_section(preload), truncated_section(preload), index_section(preload), missing_section(preload)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
      |> Kernel.<>("\n")
    end
  end

  @doc "One-line summary naming each mapped skill and its reason."
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{} = preload) do
    base =
      case preload.mapped do
        [] -> "skills: none"
        mapped -> "skills: " <> Enum.map_join(mapped, ", ", &"#{&1.name} (#{&1.reason})")
      end

    base
    |> append_when(preload.missing, "missing: ")
    |> append_when(preload.truncated, "truncated: ")
  end

  @doc "The dispatch-record event body for one preload resolution."
  @spec dispatch_record(t()) :: map()
  def dispatch_record(%__MODULE__{} = preload) do
    %{
      event: :skill_preload,
      timestamp: DateTime.utc_now(),
      last_message: summary(preload),
      skills: names(preload.mapped),
      skill_reasons: Map.new(preload.mapped, &{&1.name, &1.reason}),
      skills_missing: names(preload.missing),
      skill_reasons_missing: Map.new(preload.missing, &{&1.name, &1.reason}),
      skills_truncated: names(preload.truncated),
      skills_bytes: preload.bytes,
      skills_index_count: length(preload.index),
      skill_lanes: preload.lanes
    }
  end

  @doc "Whether any skill resolved for the ticket, from config or an override."
  @spec mapped?(t()) :: boolean()
  def mapped?(%__MODULE__{mapped: mapped}), do: mapped != []

  defp heading do
    """
    ## Skills for this ticket

    Load the mapped skills first: they fit this ticket's work, and their instructions are
    inlined below so you can start without opening a file. Every other installed skill is
    listed after them as a name and description you can load on demand.\
    """
  end

  defp mapped_section(%__MODULE__{mapped: []}), do: ""

  defp mapped_section(%__MODULE__{mapped: mapped}) do
    entries = Enum.map_join(mapped, "\n\n", &mapped_entry/1)
    "### Mapped skills (load first)\n\n" <> entries
  end

  defp mapped_entry(%Skill{} = skill) do
    ["#### `", skill.name, "` — mapped by ", skill.reason, "\n\n", String.trim(skill.text || "")]
    |> IO.iodata_to_binary()
  end

  defp truncated_section(%__MODULE__{truncated: []}), do: ""

  defp truncated_section(%__MODULE__{truncated: truncated}) do
    entries = Enum.map_join(truncated, "\n", &"- `#{&1.name}` (#{&1.reason}) — #{index_description(&1.description)}")

    "### Mapped skills over the inline budget (load on demand)\n\n" <>
      "The `agent.skills.preload_max_bytes` budget is spent before these, so load them yourself when the work needs them.\n\n" <>
      entries
  end

  defp index_section(%__MODULE__{index: []}), do: ""

  defp index_section(%__MODULE__{index: index}) do
    entries = Enum.map_join(index, "\n", &"- `#{&1.name}` — #{index_description(&1.description)}")

    "### Other installed skills (load on demand)\n\n" <> entries
  end

  defp missing_section(%__MODULE__{missing: []}), do: ""

  defp missing_section(%__MODULE__{missing: missing}) do
    entries = Enum.map_join(missing, "\n", &"- `#{&1.name}` (#{&1.reason})")

    "### Mapped skills not installed here\n\n" <>
      "These names are mapped to this ticket but have no `SKILL.md` in this workspace, so they\n" <>
      "are not inlined. Do not stall on them: record the gap in your workpad and carry on with\n" <>
      "the skills above.\n\n" <> entries
  end

  # --- resolution -----------------------------------------------------------

  defp requests(mapping, issue, lanes, feature) do
    dedupe(override_requests(mapping, issue) ++ base_requests(mapping, issue, lanes, feature))
  end

  # Per-ticket additions outrank the configured mapping in the merge order.
  defp override_requests(mapping, issue) do
    label_overrides(mapping, issue) ++ body_additions(issue)
  end

  defp label_overrides(mapping, issue) do
    issue
    |> Lane.labels()
    |> Enum.filter(&String.starts_with?(&1, "skills:"))
    |> Enum.flat_map(fn label ->
      name = label |> String.replace_prefix("skills:", "") |> String.trim()
      reason = "override:#{label}"

      case {name, Mapping.skills_for(mapping, "by_label", name)} do
        {"", _skills} -> []
        {name, []} -> [{name, reason}]
        {_name, skills} -> Enum.map(skills, &{&1, reason})
      end
    end)
  end

  defp body_additions(issue) do
    issue |> body_skills("Skills:") |> Enum.map(&{&1, "override:Skills:"})
  end

  # A `Skills:`/`Skills only:` line is ticket content. Only a line outside a
  # fenced code block counts, so a ticket that documents the syntax in an
  # example does not change its own skill set. The first matching line wins.
  defp body_skills(issue, key) do
    issue
    |> body_lines()
    |> Enum.find_value(fn line ->
      case Regex.run(~r/\A\s*#{Regex.escape(key)}\s*(.+)\z/i, line) do
        [_, names] -> names |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
        _no_match -> nil
      end
    end) || []
  end

  defp body_lines(%{description: description}) when is_binary(description) do
    description
    |> String.split(~r/\r?\n/)
    |> outside_code_fences()
  end

  defp body_lines(_issue), do: []

  defp outside_code_fences(lines) do
    lines
    |> Enum.reduce({false, []}, fn line, {fenced?, kept} ->
      trimmed = String.trim(line)

      cond do
        String.starts_with?(trimmed, "```") -> {not fenced?, kept}
        fenced? -> {true, kept}
        true -> {false, [line | kept]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # `Skills only:` replaces the configured set; per-ticket additions still apply.
  defp base_requests(mapping, issue, lanes, feature) do
    case body_skills(issue, "Skills only:") do
      [] -> configured_requests(mapping, issue, lanes, feature)
      only -> Enum.map(only, &{&1, "override:Skills only:"})
    end
  end

  defp configured_requests(mapping, issue, lanes, feature) do
    label_requests(mapping, issue) ++ lane_requests(mapping, lanes) ++ feature_requests(mapping, feature) ++ complexity_requests(mapping, issue)
  end

  defp label_requests(mapping, issue) do
    issue
    |> Lane.labels()
    |> Enum.reject(&String.starts_with?(&1, "skills:"))
    |> Enum.flat_map(fn label -> for skill <- Mapping.skills_for(mapping, "by_label", label), do: {skill, "label:#{label}"} end)
  end

  defp lane_requests(mapping, lanes) do
    Enum.flat_map(lanes, fn lane -> for skill <- Mapping.skills_for(mapping, "by_lane", lane), do: {skill, "lane:#{lane}"} end)
  end

  defp feature_requests(mapping, feature) when is_binary(feature) and feature != "" do
    for skill <- Mapping.skills_for(mapping, "by_feature", feature), do: {skill, "feature:#{feature}"}
  end

  defp feature_requests(_mapping, _feature), do: []

  defp complexity_requests(mapping, issue) do
    case Aiur.CodingAgent.complexity_level(issue) do
      level when is_integer(level) ->
        for skill <- Mapping.skills_for(mapping, "by_complexity", level), do: {skill, "complexity:#{level}"}

      _none ->
        []
    end
  end

  # First reason wins: an override that names a skill the mapping also names
  # keeps the override as the answer to "why did this worker get it".
  defp dedupe(requests) do
    requests
    |> Enum.reduce({MapSet.new(), []}, fn {name, reason}, {seen, acc} ->
      if MapSet.member?(seen, name), do: {seen, acc}, else: {MapSet.put(seen, name), [{name, reason} | acc]}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp split_by_cap(requests, installed, max_bytes) do
    requests
    |> Enum.reduce({[], [], 0}, fn {name, reason}, acc ->
      case Map.get(installed, name) do
        nil -> acc
        skill -> place_skill(acc, %Skill{name: name, reason: reason, description: skill.description, text: skill.text, path: skill.path, bytes: skill.bytes}, max_bytes)
      end
    end)
    |> then(fn {mapped, truncated, bytes} -> {Enum.reverse(mapped), Enum.reverse(truncated), bytes} end)
  end

  defp place_skill({mapped, truncated, bytes}, entry, max_bytes) do
    if bytes + entry.bytes <= max_bytes do
      {[entry | mapped], truncated, bytes + entry.bytes}
    else
      {mapped, [entry | truncated], bytes}
    end
  end

  defp missing(requests, installed) do
    for {name, reason} <- requests, not Map.has_key?(installed, name), do: %Skill{name: name, reason: reason}
  end

  defp index_entries(installed, requests) do
    requested = MapSet.new(requests, &elem(&1, 0))

    installed
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(requested, &1))
    |> Enum.sort()
    |> Enum.map(fn name ->
      %{name: name, description: Map.get(installed[name], :description)}
    end)
  end

  defp warn_missing(_issue, []), do: :ok

  defp warn_missing(issue, missing) do
    ticket = Map.get(issue, :identifier) || Map.get(issue, :id)

    Enum.each(missing, fn skill ->
      Logger.warning("skill preload: unknown skill ticket=#{inspect(ticket)} skill=#{skill.name} reason=#{skill.reason} — no SKILL.md installed in the workspace")
    end)
  end

  # --- installed skills -----------------------------------------------------

  @doc """
  The skills installed in `workspace`, keyed by directory name.

  Reads every provider install path and keeps the first copy of each skill name,
  so a `.codex/skills` link to `.claude/skills` counts once.
  """
  @spec installed_skills(Path.t() | nil) :: %{String.t() => map()}
  def installed_skills(workspace) when is_binary(workspace) do
    install_paths()
    |> Enum.reduce(%{}, fn path, acc -> read_skill_dir(Path.join(workspace, path), acc) end)
  end

  def installed_skills(_workspace), do: %{}

  defp install_paths do
    Aiur.AgentSkills.install_paths()
  rescue
    _error -> [@fallback_install_path]
  catch
    _kind, _reason -> [@fallback_install_path]
  end

  defp read_skill_dir(directory, acc) do
    case File.ls(directory) do
      {:ok, entries} -> Enum.reduce(entries, acc, &read_skill(&2, directory, &1))
      {:error, _reason} -> acc
    end
  end

  defp read_skill(acc, directory, name) do
    path = Path.join([directory, name, @skill_file])

    with true <- File.regular?(path),
         {:ok, text} <- File.read(path) do
      Map.put_new(acc, name, %{name: name, description: description(text), text: text, bytes: byte_size(text), path: path})
    else
      _unreadable -> acc
    end
  end

  # The `description:` field of the SKILL.md frontmatter, unquoted and joined.
  # Every bundled skill carries one; a skill without frontmatter still loads,
  # it just shows up in the index without a description.
  @doc false
  @spec description(String.t()) :: String.t() | nil
  def description(text) when is_binary(text) do
    case Regex.run(~r/\A---\r?\n(.*?)\r?\n---/s, text) do
      [_, frontmatter] -> parse_description(frontmatter)
      _no_frontmatter -> nil
    end
  end

  def description(_text), do: nil

  defp parse_description(frontmatter) do
    lines = String.split(frontmatter, ~r/\r?\n/)

    case Enum.find_index(lines, &Regex.match?(~r/\Adescription:/, &1)) do
      nil -> nil
      index -> lines |> Enum.drop(index) |> collect_description() |> unquote_description()
    end
  end

  defp collect_description([first | rest]) do
    inline = first |> String.replace_prefix("description:", "") |> String.trim() |> block_scalar_marker()
    continuation = rest |> Enum.take_while(&continuation?/1) |> Enum.map(&String.trim/1)

    [inline | continuation] |> Enum.reject(&(&1 == "")) |> Enum.join(" ")
  end

  defp block_scalar_marker(value) when value in [">", "|", ">-", "|-", ">+", "|+"], do: ""
  defp block_scalar_marker(value), do: value

  defp continuation?(line) do
    case line do
      "---" <> _rest -> false
      <<" ", _rest::binary>> -> true
      <<"\t", _rest::binary>> -> true
      _ -> false
    end
  end

  defp unquote_description(nil), do: nil

  defp unquote_description(description) do
    description = String.replace(description, ~r/\s+/, " ") |> String.trim()

    case description do
      <<"\"", _rest::binary>> -> trim_pair(description, "\"")
      <<"'", _rest::binary>> -> trim_pair(description, "'")
      _plain -> nilify(description)
    end
  end

  defp trim_pair(value, quote) do
    size = byte_size(value)

    if size > 1 and binary_part(value, size - 1, 1) == quote do
      binary_part(value, 1, size - 2) |> String.replace(~r/\\"/, "\"") |> nilify()
    else
      nilify(value)
    end
  end

  defp nilify(""), do: nil
  defp nilify(value), do: value

  defp index_description(nil), do: "no description in its SKILL.md"
  defp index_description(description), do: shorten(description)

  defp shorten(description) when byte_size(description) <= @index_description_chars, do: description

  defp shorten(description) do
    shortened = binary_part(description, 0, @index_description_chars)
    # Cut on a word boundary when there is one near the limit.
    case Regex.run(~r/\A(.*)\s/, shortened, capture: :all_but_first) do
      [head | _] when byte_size(head) > 0 -> head <> "…"
      _ -> shortened <> "…"
    end
  end

  defp names(skills), do: Enum.map(skills, & &1.name)

  defp append_when(text, [] = _entries, _label), do: text

  defp append_when(text, entries, label) do
    text <> "; " <> label <> Enum.map_join(entries, ", ", & &1.name)
  end

  defp settings(opts) do
    case Keyword.get_lazy(opts, :settings, fn -> Aiur.Config.settings() end) do
      {:ok, settings} -> settings
      {:error, _reason} -> nil
      %_{} = settings -> settings
      %{} = settings -> settings
      _unavailable -> nil
    end
  end

  defp agent_skills(%{agent: %{skills: skills}}), do: skills
  defp agent_skills(_settings), do: nil

  # The owning feature comes from the durable build-order registry. A registry
  # timeout means "no feature reason", not a failed dispatch: the ticket still
  # gets its lane, label and complexity skills.
  defp feature_slug(issue) do
    with identifier when is_binary(identifier) <- Map.get(issue, :identifier),
         {number, ""} <- Integer.parse(identifier),
         {:ok, owner} <- Features.owner(number, timeout: @owner_timeout_ms) do
      Map.get(owner, :feature)
    else
      _none -> nil
    end
  catch
    _kind, _reason -> nil
  end
end
