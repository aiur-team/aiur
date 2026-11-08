defmodule Aiur.Config.SkillsMapping do
  @moduledoc """
  Normalizes and validates the `agent.skills` config that maps a ticket's lane,
  feature, epic, label and complexity to the skills its worker loads first.

  The operator-facing shape:

      agent:
        skills:
          preload_max_bytes: 32768
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

  A value is a list of skill names or a single skill name. Skill names are never
  validated against installed skills at load time: the workspace the worker runs
  in decides which skills exist, and an unknown name has to reach the dispatch
  record as a visible warning instead of failing the whole config. Shape,
  dimension keys and byte caps are validated here.
  """

  @dimensions ["by_lane", "by_feature", "by_epic", "by_label", "by_complexity"]
  @dimension_atoms %{
    "by_lane" => :by_lane,
    "by_feature" => :by_feature,
    "by_epic" => :by_epic,
    "by_label" => :by_label,
    "by_complexity" => :by_complexity
  }
  @keys ["preload_max_bytes" | @dimensions]
  @default_max_bytes 32_768
  # A skill name has to address a directory under a workspace skill path.
  @skill_name_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/

  @type dimension :: String.t()
  @type normalized :: %{
          preload_max_bytes: pos_integer(),
          by_lane: %{String.t() => [String.t()]},
          by_feature: %{String.t() => [String.t()]},
          by_epic: %{String.t() => [String.t()]},
          by_label: %{String.t() => [String.t()]},
          by_complexity: %{pos_integer() => [String.t()]}
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

  @doc "The empty mapping."
  @spec empty() :: normalized()
  def empty do
    %{
      preload_max_bytes: @default_max_bytes,
      by_lane: %{},
      by_feature: %{},
      by_epic: %{},
      by_label: %{},
      by_complexity: %{}
    }
  end

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
    Enum.any?(@dimensions, &dimension_configured?(mapping, &1))
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

  defp put_normalized({key, value}, acc) do
    case normalize_key(key) do
      "preload_max_bytes" -> Map.put(acc, :preload_max_bytes, normalize_bytes(value))
      dimension when dimension in @dimensions -> Map.put(acc, Map.fetch!(@dimension_atoms, dimension), normalize_entries(dimension, value))
      other -> Map.put(acc, :unknown, Map.put(Map.get(acc, :unknown, %{}), other, value))
    end
  end

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
         :ok <- validate_max_bytes(Map.get(raw, "preload_max_bytes") || Map.get(raw, :preload_max_bytes)) do
      validate_dimensions(raw)
    end
  end

  defp validate_unknown_keys(raw) do
    unknown =
      raw
      |> Enum.map(fn {key, _value} -> normalize_key(key) end)
      |> Enum.reject(&(&1 in @keys))

    case unknown do
      [] -> :ok
      keys -> {:error, "agent.skills has unknown keys #{Enum.join(Enum.sort(keys), ", ")}; allowed keys are #{Enum.join(@keys, ", ")}"}
    end
  end

  defp validate_max_bytes(nil), do: :ok

  defp validate_max_bytes(bytes) when is_integer(bytes) and bytes > 0, do: :ok

  defp validate_max_bytes(_bytes),
    do: {:error, "agent.skills.preload_max_bytes must be a positive integer"}

  defp validate_dimensions(raw) do
    raw
    |> Enum.map(fn {key, value} -> {normalize_key(key), value} end)
    |> Enum.reject(fn {key, _value} -> key not in @dimensions end)
    |> Enum.reduce_while(:ok, fn {dimension, value}, :ok ->
      case validate_entries(dimension, value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_entries(dimension, %{} = entries) do
    entries
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.reduce_while(:ok, fn {key, skills}, :ok ->
      with :ok <- validate_key(dimension, key),
           :ok <- validate_skills(dimension, key, skills) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp validate_entries(dimension, _value), do: {:error, "agent.skills.#{dimension} must be a map"}

  defp validate_key("by_complexity", key) when is_integer(key) and key > 0, do: :ok
  defp validate_key("by_complexity", _key), do: {:error, "agent.skills.by_complexity keys must be positive complexity levels"}

  defp validate_key(_dimension, key) when is_binary(key) and key != "", do: :ok
  defp validate_key(dimension, _key), do: {:error, "agent.skills.#{dimension} keys must be non-empty names"}

  defp validate_skills(_dimension, _key, skill) when is_binary(skill) do
    if valid_skill_name?(skill), do: :ok, else: {:error, "agent.skills names invalid skills #{skill}; use skill directory names"}
  end

  defp validate_skills(dimension, key, skills) when is_list(skills) and skills != [] do
    case Enum.reject(skills, &valid_skill_name?/1) do
      [] -> :ok
      bad -> {:error, "agent.skills.#{dimension}.#{key} names invalid skills #{Enum.join(bad, ", ")}; use skill directory names"}
    end
  end

  defp validate_skills(dimension, key, _skills),
    do: {:error, "agent.skills.#{dimension}.#{key} must be a skill name or a non-empty list of skill names"}

  defp valid_skill_name?(skill), do: is_binary(skill) and Regex.match?(@skill_name_pattern, skill)

  # The `agent.skills` reference-table rows live here rather than beside the
  # field in `Aiur.Config.Schema.Agent`, which is at the file-size limit.
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-00 agent.skills
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-detail agent.skills | map | `%{}` | Maps a ticket's lane, owning feature, epic, labels and complexity to the skills its worker loads first. See [skills](/skills#matching-skills-to-a-ticket). |
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-00 agent.skills.preload_max_bytes
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-detail agent.skills.preload_max_bytes | integer | `32768` | Byte budget for skill instructions inlined into the cold prompt; mapped skills past it are listed to load on demand and reported as truncated. |
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
end
