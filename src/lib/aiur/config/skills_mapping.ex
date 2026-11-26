defmodule Aiur.Config.SkillsMapping do
  @moduledoc """
  Normalizes and validates the `agent.skills` config that maps a ticket's lane,
  feature, epic, label and complexity to the skills its worker loads first.

  The operator-facing shape:

      agent:
        skills:
          preload_max_bytes: 32768
          strict: false
          by_lane:
            art: [pixel-art, palette]
          by_feature:
            items-ui: [ce-work]
          by_epic:
            v1-launch: [ce-plan]
          by_label:
            design: [design-import]
          by_complexity:
            1: [ce-work]
          recommended:
            by_lane:
              art: [sprite-sheets]

  A value is a list of skill names or a single skill name. Skill names are never
  validated against installed skills at load time: the workspace the worker runs
  in decides which skills exist, and an unknown name has to reach the dispatch
  record as a visible warning instead of failing the whole config. Shape,
  dimension keys and byte caps are validated here.

  Mapped skills are mandatory: they are always inlined, even past the byte
  budget. `strict: true` turns a mapped skill with no `SKILL.md`, or a mapped
  set over the budget, into a blocked dispatch instead of a warning.

  `recommended` takes the same five dimensions. A recommended skill is listed to
  the worker with its description and path rather than inlined, so it never
  spends the `preload_max_bytes` budget.
  """

  @dimensions ["by_lane", "by_feature", "by_epic", "by_label", "by_complexity"]
  @dimension_atoms %{
    "by_lane" => :by_lane,
    "by_feature" => :by_feature,
    "by_epic" => :by_epic,
    "by_label" => :by_label,
    "by_complexity" => :by_complexity
  }
  @keys ["preload_max_bytes", "strict", "recommended" | @dimensions]
  @default_max_bytes 32_768
  # A skill name has to address a directory under a workspace skill path.
  @skill_name_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/

  @type dimension :: String.t()
  @type normalized :: %{
          preload_max_bytes: pos_integer(),
          strict: boolean(),
          by_lane: %{String.t() => [String.t()]},
          by_feature: %{String.t() => [String.t()]},
          by_epic: %{String.t() => [String.t()]},
          by_label: %{String.t() => [String.t()]},
          by_complexity: %{pos_integer() => [String.t()]},
          recommended: map()
        }

  @doc "The keys accepted under `agent.skills`."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @spec default_max_bytes() :: pos_integer()
  def default_max_bytes, do: @default_max_bytes

  @doc """
  Normalize a raw `agent.skills` map into the resolution shape.

  Unknown keys and malformed values survive normalization as-is so
  `validate/2` can name them; a `nil` or non-map value normalizes to the empty
  mapping.
  """
  @spec normalize(nil | map() | term()) :: normalized() | term()
  def normalize(nil), do: empty()
  def normalize(%{} = raw), do: Enum.reduce(raw, empty(), &put_normalized/2)
  def normalize(other), do: other

  @doc """
  Merge a global raw `agent.skills` map under a project raw map.

  Maps merge by key: the project adds to the global mapping per dimension, and
  a project entry replaces the global entry with the same key (keys compared as
  `normalize/1` compares them). A project entry of `[]` removes that key. Scalars
  take the project value. Raw values stay raw, so `validate/1` still names a bad
  value.
  """
  @spec merge(term(), term()) :: term()
  def merge(%{} = global, %{} = project) do
    global
    |> Map.merge(project, fn key, global_value, project_value ->
      merge_dimension(normalize_key(key), global_value, project_value)
    end)
    |> Map.new(fn {key, value} -> {key, drop_removed(normalize_key(key), value)} end)
  end

  def merge(global, nil), do: global
  def merge(_global, project), do: project

  defp merge_dimension(dimension, %{} = global, %{} = project) when dimension in @dimensions do
    shadowed = MapSet.new(Map.keys(project), &normalize_entry_key(dimension, &1))

    global
    |> Map.reject(fn {key, _skills} -> normalize_entry_key(dimension, key) in shadowed end)
    |> Map.merge(project)
  end

  defp merge_dimension(_key, %{} = global, %{} = project), do: merge(global, project)
  defp merge_dimension(_key, _global, project), do: project

  defp drop_removed(dimension, %{} = entries) when dimension in @dimensions,
    do: Map.reject(entries, fn {_key, skills} -> skills == [] end)

  defp drop_removed(_key, value), do: value

  @doc "The empty mapping."
  @spec empty() :: normalized()
  def empty do
    Map.merge(empty_dimensions(), %{preload_max_bytes: @default_max_bytes, strict: false, recommended: empty_dimensions()})
  end

  defp empty_dimensions, do: Map.new(@dimension_atoms, fn {_name, atom} -> {atom, %{}} end)

  @doc "The `recommended` dimensions, in the shape `skills_for/3` reads."
  @spec recommended(normalized() | term()) :: map()
  def recommended(%{recommended: %{} = recommended}), do: recommended
  def recommended(_mapping), do: empty_dimensions()

  @doc "Skill names configured for `dimension` and `key`, in configured order."
  @spec skills_for(normalized(), dimension(), term()) :: [String.t()]
  def skills_for(%{} = mapping, dimension, key) when dimension in @dimensions do
    case Map.get(mapping, Map.fetch!(@dimension_atoms, dimension)) do
      %{} = entries -> Map.get(entries, key, [])
      _missing -> []
    end
  end

  def skills_for(_mapping, _dimension, _key), do: []

  @doc "Whether the mapping configures any skill at all."
  @spec configured?(normalized() | term()) :: boolean()
  def configured?(%{} = mapping) do
    Enum.any?(@dimensions, &(dimension_configured?(mapping, &1) or dimension_configured?(recommended(mapping), &1)))
  end

  def configured?(_mapping), do: false

  @doc "Whether `dimension` names at least one skill."
  @spec dimension_configured?(normalized() | term(), dimension()) :: boolean()
  def dimension_configured?(%{} = mapping, dimension) when dimension in @dimensions do
    case Map.get(mapping, Map.fetch!(@dimension_atoms, dimension)) do
      %{} = entries -> Enum.any?(entries, fn {_key, skills} -> skills != [] end)
      _ -> false
    end
  end

  def dimension_configured?(_mapping, _dimension), do: false

  @doc "The configured inlined-skill byte cap, falling back to the default."
  @spec max_bytes(normalized() | term()) :: pos_integer()
  def max_bytes(%{preload_max_bytes: bytes}) when is_integer(bytes) and bytes > 0, do: bytes
  def max_bytes(_mapping), do: @default_max_bytes

  @doc "Whether a missing or over-budget mapped skill blocks the dispatch."
  @spec strict?(normalized() | term()) :: boolean()
  def strict?(%{strict: true}), do: true
  def strict?(_mapping), do: false

  defp put_normalized({key, value}, acc) do
    case normalize_key(key) do
      "preload_max_bytes" -> Map.put(acc, :preload_max_bytes, normalize_bytes(value))
      "strict" -> Map.put(acc, :strict, value)
      "recommended" -> Map.put(acc, :recommended, normalize_recommended(value))
      dimension when dimension in @dimensions -> Map.put(acc, Map.fetch!(@dimension_atoms, dimension), normalize_entries(dimension, value))
      other -> Map.put(acc, :unknown, Map.put(Map.get(acc, :unknown, %{}), other, value))
    end
  end

  # Unknown keys under `recommended` are dropped here; `validate/1` names them.
  defp normalize_recommended(%{} = raw) do
    Enum.reduce(raw, empty_dimensions(), fn {key, value}, acc ->
      case normalize_key(key) do
        dimension when dimension in @dimensions -> Map.put(acc, Map.fetch!(@dimension_atoms, dimension), normalize_entries(dimension, value))
        _unknown -> acc
      end
    end)
  end

  defp normalize_recommended(_other), do: empty_dimensions()

  defp normalize_bytes(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {bytes, ""} -> bytes
      _ -> value
    end
  end

  defp normalize_bytes(value), do: value

  defp normalize_entries(dimension, %{} = entries) do
    Map.new(entries, fn {key, value} -> {normalize_entry_key(dimension, key), normalize_skills(value)} end)
  end

  defp normalize_entries(_dimension, other), do: other

  # Complexity keys are complexity levels, so "3" and 3 name the same entry.
  defp normalize_entry_key("by_complexity", key) when is_integer(key), do: key

  defp normalize_entry_key("by_complexity", key) when is_binary(key) do
    case Integer.parse(String.trim(key)) do
      {level, ""} -> level
      _not_a_level -> normalize_key(key)
    end
  end

  defp normalize_entry_key(_dimension, key), do: normalize_key(key)

  defp normalize_skills(skills) when is_binary(skills), do: [normalize_skill(skills)]

  defp normalize_skills(skills) when is_list(skills) do
    skills |> Enum.map(&normalize_skill/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
  end

  defp normalize_skills(other), do: other

  defp normalize_skill(skill) when is_binary(skill), do: String.trim(skill)
  defp normalize_skill(skill), do: skill

  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> String.trim() |> String.downcase()
  defp normalize_key(key) when is_binary(key), do: key |> String.trim() |> String.downcase()
  defp normalize_key(key), do: key

  @doc """
  Validate a raw `agent.skills` value.

  Returns `:ok` or `{:error, message}` with one operator-readable message. The
  first problem wins: a config that names an unknown dimension cannot be
  trusted to name its skill lists correctly either.
  """
  @spec validate(nil | term()) :: :ok | {:error, String.t()}
  def validate(nil), do: :ok
  def validate(%{} = raw), do: validate_raw(raw)
  def validate(_other), do: {:error, "agent.skills must be a map"}

  defp validate_raw(raw) do
    with :ok <- validate_unknown_keys(raw),
         :ok <- validate_max_bytes(Map.get(raw, "preload_max_bytes") || Map.get(raw, :preload_max_bytes)),
         :ok <- validate_strict(Map.get(raw, "strict", Map.get(raw, :strict))),
         :ok <- validate_dimensions("agent.skills", raw) do
      raw
      |> Enum.find(fn {key, _value} -> normalize_key(key) == "recommended" end)
      |> validate_recommended()
    end
  end

  defp validate_recommended(nil), do: :ok

  defp validate_recommended({_key, %{} = raw}) do
    with :ok <- validate_unknown_keys("agent.skills.recommended", raw, @dimensions) do
      validate_dimensions("agent.skills.recommended", raw)
    end
  end

  defp validate_recommended({_key, _other}), do: {:error, "agent.skills.recommended must be a map"}

  defp validate_unknown_keys(raw), do: validate_unknown_keys("agent.skills", raw, @keys)

  defp validate_unknown_keys(path, raw, allowed) do
    unknown =
      raw
      |> Enum.map(fn {key, _value} -> normalize_key(key) end)
      |> Enum.reject(&(&1 in allowed))

    case unknown do
      [] -> :ok
      keys -> {:error, "#{path} has unknown keys #{Enum.join(Enum.sort(keys), ", ")}; allowed keys are #{Enum.join(allowed, ", ")}"}
    end
  end

  defp validate_max_bytes(nil), do: :ok

  defp validate_max_bytes(bytes) when is_integer(bytes) and bytes > 0, do: :ok

  defp validate_max_bytes(_bytes),
    do: {:error, "agent.skills.preload_max_bytes must be a positive integer"}

  defp validate_strict(strict) when is_boolean(strict) or is_nil(strict), do: :ok
  defp validate_strict(_strict), do: {:error, "agent.skills.strict must be true or false"}

  defp validate_dimensions(prefix, raw) do
    raw
    |> Enum.map(fn {key, value} -> {normalize_key(key), value} end)
    |> Enum.reject(fn {key, _value} -> key not in @dimensions end)
    |> Enum.reduce_while(:ok, fn {dimension, value}, :ok ->
      case validate_entries("#{prefix}.#{dimension}", dimension, value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_entries(path, dimension, %{} = entries) do
    entries
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.reduce_while(:ok, fn {key, skills}, :ok ->
      with :ok <- validate_key(path, dimension, key),
           :ok <- validate_skills(path, key, skills) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp validate_entries(path, _dimension, _value), do: {:error, "#{path} must be a map"}

  defp validate_key(_path, "by_complexity", key) when is_integer(key) and key > 0, do: :ok
  defp validate_key(path, "by_complexity", _key), do: {:error, "#{path} keys must be positive complexity levels"}

  defp validate_key(_path, _dimension, key) when is_binary(key) and key != "", do: :ok
  defp validate_key(path, _dimension, _key), do: {:error, "#{path} keys must be non-empty names"}

  defp validate_skills(_path, _key, skill) when is_binary(skill) do
    if valid_skill_name?(skill), do: :ok, else: {:error, "agent.skills names invalid skills #{skill}; use skill directory names"}
  end

  defp validate_skills(path, key, skills) when is_list(skills) and skills != [] do
    case Enum.reject(skills, &valid_skill_name?/1) do
      [] -> :ok
      bad -> {:error, "#{path}.#{key} names invalid skills #{Enum.join(bad, ", ")}; use skill directory names"}
    end
  end

  defp validate_skills(path, key, _skills),
    do: {:error, "#{path}.#{key} must be a skill name or a non-empty list of skill names"}

  defp valid_skill_name?(skill), do: is_binary(skill) and Regex.match?(@skill_name_pattern, skill)

  # The `agent.skills` reference-table rows live here rather than beside the
  # field in `Aiur.Config.Schema.Agent`, which is at the file-size limit.
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-00 agent.skills
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-detail agent.skills | map | `%{}` | Maps a ticket's lane, owning feature, epic, labels and complexity to the skills its worker loads first. A project `.aiur/config` inherits `agent.skills` from `~/.aiur/config` and overrides it per entry; see [skills](/skills#matching-skills-to-a-ticket). |
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-00 agent.skills.preload_max_bytes
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-detail agent.skills.preload_max_bytes | integer | `32768` | Byte budget for skill instructions inlined into the cold prompt. Mapped skills are never truncated: a mapped set past it is still inlined and raises a warning alert, or blocks the dispatch under `agent.skills.strict`. |
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-00 agent.skills.strict
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-detail agent.skills.strict | boolean | `false` | Makes mapped skills a dispatch requirement. When `true`, a mapped skill with no `SKILL.md` in the workspace, or a mapped set over `preload_max_bytes`, starts no worker: the ticket pauses as a preflight failure and an attention alert names the ticket, the skills and their mapping reasons. When `false`, the same cases dispatch and raise a warning alert. |
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-00 agent.skills.by_lane
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-detail agent.skills.by_lane | map | `%{}` | Lane slug to skill names. A lane comes from the `lane:`, `area:` and `build-lane:` label suffixes and from a configured lane's label matchers. |
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-00 agent.skills.by_feature
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-detail agent.skills.by_feature | map | `%{}` | Owning feature slug to skill names. |
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-00 agent.skills.by_epic
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-detail agent.skills.by_epic | map | `%{}` | Epic slug to skill names. The epic is the one that holds the ticket's owning feature in the build-order registry. |
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-00 agent.skills.by_label
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-detail agent.skills.by_label | map | `%{}` | Ticket label to skill names. A `skills:<name>` label selects the same entry, or names one skill directly. |
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-00 agent.skills.by_complexity
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-detail agent.skills.by_complexity | map | `%{}` | Complexity level to skill names. |
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-00 agent.skills.recommended
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-detail agent.skills.recommended | map | `%{}` | The same five `by_*` maps, for skills that fit the ticket but are not inlined: the worker sees each one's name, description and path, and loads it on demand. Never counts against `preload_max_bytes`. See [recommended skills](/skills#recommended-skills). |
end
