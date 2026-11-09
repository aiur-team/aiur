defmodule Aiur.AgentSkills.Preload do
  @moduledoc """
  Maps a ticket to the skills its worker should load first.

  A worker's cold-start prompt used to carry no skill priority at all: every
  installed skill looked the same, so a pixel-art ticket started with the same
  context as a CI ticket. This module resolves which skills fit the ticket —
  from its lanes, its owning feature, its epic, its labels and its complexity —
  and renders a prompt block that inlines those skills' `SKILL.md` text while
  listing every other installed skill as a one-line name and description to
  load on demand.

  Merge order is the order the plan settled on: per-ticket override, label, lane,
  feature, epic, complexity. A set is combined rather than replaced, except for
  the explicit `Skills only:` body line. Each resolved skill keeps the reason that
  selected it, so the dispatch record and `aiur agents` can answer "why did this
  worker get this skill".

  The epic comes from the build-order registry: it is the epic record whose
  ordered feature list holds the ticket's owning feature. A feature no epic holds
  contributes no epic reason and no error.

  Skill text comes from the workspace after install, so the target repository's
  own skills and aiur's vendored ones both count. A name that resolves but is not
  installed is never dropped silently: it lands in `missing`, logs a warning and
  appears in the prompt block and the dispatch record.
  """

  require Logger

  alias Aiur.AgentSkills.Registry
  alias Aiur.BuildOrder.Features
  alias Aiur.Config.SkillsMapping
  alias Aiur.Lane

  # The build-order registry reads (owning feature, then its epic) run in the
  # dispatch path; 100 ms is the same bound TelemetryCohort uses for the owner
  # lookup.
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
    * `:epic` — an already-resolved epic slug for that feature.

  A missing or unreadable workspace resolves to "no installed skills" rather
  than raising: prompt building must never fail because a workspace is
  mid-materialize.
  """
  @spec resolve(Aiur.Issue.t() | map(), Path.t() | nil, keyword()) :: t()
  def resolve(issue, workspace, opts \\ []) do
    settings = settings(opts)
    mapping = Keyword.get_lazy(opts, :mapping, fn -> SkillsMapping.normalize(agent_skills(settings)) end)
    installed = Keyword.get_lazy(opts, :installed, fn -> installed_skills(workspace) end)
    lanes = Keyword.get_lazy(opts, :lanes, fn -> Lane.resolve(issue, settings) end)
    feature = Keyword.get_lazy(opts, :feature, fn -> feature_slug(issue, opts) end)
    epic = Keyword.get_lazy(opts, :epic, fn -> epic_slug(feature, mapping, opts) end)
    requests = requests(mapping, issue, lanes, feature, epic)
    max_bytes = SkillsMapping.max_bytes(mapping)
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
      configured?: SkillsMapping.configured?(mapping)
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

  @doc "The machine-readable preload facts `aiur agents --json` reports per running worker."
  @spec report(t()) :: map()
  def report(%__MODULE__{} = preload) do
    %{
      mapped: Enum.map(preload.mapped, &%{name: &1.name, reason: &1.reason}),
      truncated: names(preload.truncated),
      missing: names(preload.missing),
      bytes: preload.bytes,
      max_bytes: preload.max_bytes
    }
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

  defp requests(mapping, issue, lanes, feature, epic) do
    dedupe(override_requests(mapping, issue) ++ base_requests(mapping, issue, lanes, feature, epic))
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

      case {name, SkillsMapping.skills_for(mapping, "by_label", name)} do
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
  defp base_requests(mapping, issue, lanes, feature, epic) do
    case body_skills(issue, "Skills only:") do
      [] -> configured_requests(mapping, issue, lanes, feature, epic)
      only -> Enum.map(only, &{&1, "override:Skills only:"})
    end
  end

  defp configured_requests(mapping, issue, lanes, feature, epic) do
    label_requests(mapping, issue) ++
      lane_requests(mapping, lanes) ++
      feature_requests(mapping, feature) ++ epic_requests(mapping, epic) ++ complexity_requests(mapping, issue)
  end

  defp label_requests(mapping, issue) do
    issue
    |> Lane.labels()
    |> Enum.reject(&String.starts_with?(&1, "skills:"))
    |> Enum.flat_map(fn label -> for skill <- SkillsMapping.skills_for(mapping, "by_label", label), do: {skill, "label:#{label}"} end)
  end

  defp lane_requests(mapping, lanes) do
    Enum.flat_map(lanes, fn lane -> for skill <- SkillsMapping.skills_for(mapping, "by_lane", lane), do: {skill, "lane:#{lane}"} end)
  end

  defp feature_requests(mapping, feature) when is_binary(feature) and feature != "" do
    for skill <- SkillsMapping.skills_for(mapping, "by_feature", feature), do: {skill, "feature:#{feature}"}
  end

  defp feature_requests(_mapping, _feature), do: []

  defp epic_requests(mapping, epic) when is_binary(epic) and epic != "" do
    for skill <- SkillsMapping.skills_for(mapping, "by_epic", epic), do: {skill, "epic:#{epic}"}
  end

  defp epic_requests(_mapping, _epic), do: []

  defp complexity_requests(mapping, issue) do
    case Aiur.CodingAgent.complexity_level(issue) do
      level when is_integer(level) ->
        for skill <- SkillsMapping.skills_for(mapping, "by_complexity", level), do: {skill, "complexity:#{level}"}

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

  # The reading and frontmatter-parsing concern lives in `Registry`; these
  # delegates keep the public surface on `Preload`, which resolves the mapping.
  @doc "The skills installed in `workspace`, keyed by directory name."
  @spec installed_skills(Path.t() | nil) :: %{String.t() => map()}
  defdelegate installed_skills(workspace), to: Registry

  @doc false
  @spec description(String.t()) :: String.t() | nil
  defdelegate description(text), to: Registry

  defp index_description(description), do: Registry.index_description(description)

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
  defp feature_slug(issue, opts) do
    server = Keyword.get(opts, :feature_server, Features)

    with identifier when is_binary(identifier) <- Map.get(issue, :identifier),
         {number, ""} <- Integer.parse(identifier),
         {:ok, owner} <- Features.owner(number, timeout: @owner_timeout_ms, server: server) do
      Map.get(owner, :feature)
    else
      _none -> nil
    end
  catch
    _kind, _reason -> nil
  end

  # The epic above the owning feature comes from the same registry: it is the
  # epic record whose ordered feature list holds that feature. The read runs only
  # when `by_epic` maps a skill, so an unmapped config pays nothing for it. A
  # registry timeout or an unreadable epic file means "no epic reason", never a
  # failed dispatch.
  defp epic_slug(feature, mapping, opts) when is_binary(feature) and feature != "" do
    if SkillsMapping.dimension_configured?(mapping, "by_epic"), do: epic_from_registry(feature, opts)
  end

  defp epic_slug(_feature, _mapping, _opts), do: nil

  defp epic_from_registry(feature, opts) do
    server = Keyword.get(opts, :feature_server, Features)

    with {:ok, %{epics: epics}} <- Features.epics(timeout: @owner_timeout_ms, server: server),
         %{slug: slug} <- Enum.find(epics, &(feature in Map.get(&1, :features, []))) do
      slug
    else
      _none -> nil
    end
  catch
    _kind, _reason -> nil
  end
end
