defmodule Aiur.Capacity.PolicyConfig do
  @moduledoc """
  The capacity policy's configuration: shape validation for each layer, the
  tighten-only rule between layers, and the merged effective policy.

  The machine file (L1) owns every key. A project config (L3) may only lower a
  limit, raise a reserve or add `last_resort`; `aiur set` (L5) may only raise a
  reserve. A value that would loosen a lower layer is refused and the error names
  both layers. With no `capacity` block anywhere the effective policy has no
  reserve, no limit and no last-resort source, so it allows every route.
  """

  alias Aiur.Machine.Settings

  @billing ~w(subscription prepaid metered unknown)
  @periods ~w(daily_usd weekly_usd monthly_usd)
  @layer_names %{"L1" => "machine", "L3" => "project", "L5" => "runtime"}
  @runtime_key ~r/\Acapacity\.sources\.([A-Za-z0-9_-]+)\.reserve\.percent\z/

  @type layer :: :machine | :project
  @type policy :: %{sources: %{String.t() => map()}, limits: map(), default_burn_percent_per_hour: number() | nil}

  @doc "The policy for a backend no layer names: everything allowed."
  @spec default_source() :: map()
  def default_source do
    %{billing: "unknown", last_resort: false, serves: ["coding"], reserve: %{percent: 0, accounts: :all}, limits: no_limits()}
  end

  @doc "The effective source policy for `backend`."
  @spec source(policy(), String.t()) :: map()
  def source(%{sources: sources}, backend), do: Map.get(sources, backend, default_source())

  # --- shape -----------------------------------------------------------------

  @doc "Changeset errors for a `sources` map at `layer`, keyed under `field`."
  @spec source_errors(atom(), term(), layer()) :: keyword(String.t())
  def source_errors(_field, nil, _layer), do: []

  def source_errors(field, sources, layer) when is_map(sources) do
    Enum.flat_map(sources, fn {backend, source} ->
      if is_map(source),
        do: Enum.flat_map(source, &source_key_errors(&1, layer, "#{backend}.")),
        else: ["#{backend} must be a mapping"]
    end)
    |> Enum.map(&{field, &1})
  end

  def source_errors(field, _other, _layer), do: [{field, "must be a mapping of backend names"}]

  @doc "Changeset errors for a `limits` map."
  @spec limit_errors(atom(), term()) :: keyword(String.t())
  def limit_errors(field, limits), do: Enum.map(limits_errors(limits, ""), &{field, &1})

  defp source_key_errors({"billing", value}, :machine, p), do: check(value in @billing, "#{p}billing must be one of #{Enum.join(@billing, ", ")}")
  defp source_key_errors({"last_resort", value}, _layer, p), do: check(is_boolean(value), "#{p}last_resort must be a boolean")
  defp source_key_errors({"serves", value}, :machine, p), do: check(string_list?(value), "#{p}serves must be a list of work kinds")
  defp source_key_errors({"limits", value}, _layer, p), do: limits_errors(value, "#{p}limits.")
  defp source_key_errors({"reserve", value}, layer, p) when is_map(value), do: Enum.flat_map(value, &reserve_errors(&1, layer, "#{p}reserve."))
  defp source_key_errors({"reserve", _value}, _layer, p), do: ["#{p}reserve must be a mapping"]
  defp source_key_errors({key, _value}, :project, p) when key in ~w(billing serves), do: ["#{p}#{key} is machine-owned; set it in ~/.aiur/machine"]
  defp source_key_errors({key, _value}, _layer, p), do: ["#{p}#{key} is an unknown key"]

  defp reserve_errors({"percent", value}, _layer, p), do: check(is_number(value) and value >= 0 and value <= 100, "#{p}percent must be a number from 0 to 100")
  defp reserve_errors({"accounts", value}, :machine, p), do: check(string_list?(value), "#{p}accounts must be a list of account names")
  defp reserve_errors({"accounts", _value}, :project, p), do: ["#{p}accounts is machine-owned; set it in ~/.aiur/machine"]
  defp reserve_errors({key, _value}, _layer, p), do: ["#{p}#{key} is an unknown key"]

  defp limits_errors(nil, _p), do: []

  defp limits_errors(limits, p) when is_map(limits) do
    Enum.flat_map(limits, fn
      {key, value} when key in @periods -> check(is_nil(value) or (is_number(value) and value >= 0), "#{p}#{key} must be a non-negative number")
      {key, _value} -> ["#{p}#{key} is an unknown key"]
    end)
  end

  defp limits_errors(_other, ""), do: ["must be a mapping"]
  defp limits_errors(_other, p), do: ["#{String.trim_trailing(p, ".")} must be a mapping"]

  defp check(true, _message), do: []
  defp check(false, message), do: [message]

  defp string_list?(value), do: is_list(value) and Enum.all?(value, &(is_binary(&1) and &1 != ""))

  # --- merge -----------------------------------------------------------------

  @doc """
  Merges the machine capacity (L1) with the project capacity (L3, which already
  carries any accepted L5 reserve). Both are plain maps with string keys under
  `sources` and `limits`. Returns the policy, or the first loosening value.
  """
  @spec effective(map() | struct() | nil, map() | struct() | nil) :: {:ok, policy()} | {:error, {:invalid_workflow_config, String.t()}}
  def effective(machine, project) do
    machine = plain(machine)
    project = plain(project)

    with :ok <- tightens(machine, project, "L3") do
      backends = Enum.uniq(Map.keys(machine["sources"]) ++ Map.keys(project["sources"]))
      sources = Map.new(backends, &{&1, merge_source(machine["sources"][&1] || %{}, project["sources"][&1] || %{})})

      {:ok,
       %{
         sources: sources,
         limits: merge_limits(machine["limits"], project["limits"]),
         default_burn_percent_per_hour: machine["default_burn_percent_per_hour"]
       }}
    end
  end

  @doc "Reads L1 from `~/.aiur/machine` and L3/L5 from the loaded workflow config."
  @spec effective() :: {:ok, policy()} | {:error, term()}
  def effective do
    with {:ok, machine} <- Settings.get(),
         {:ok, settings} <- Aiur.Config.settings() do
      effective(machine.capacity, settings.capacity)
    end
  end

  @doc "Refuses a project value that loosens the machine (layer `layer` names who set it)."
  @spec tightens(map() | struct() | nil, map() | struct() | nil, String.t()) :: :ok | {:error, {:invalid_workflow_config, String.t()}}
  def tightens(machine, project, layer) do
    machine = plain(machine)
    project = plain(project)

    global = Enum.map(@periods, &{"capacity.limits.#{&1}", :limit, project["limits"][&1], machine["limits"][&1]})

    per_source =
      Enum.flat_map(project["sources"], fn {backend, source} ->
        base = machine["sources"][backend] || %{}
        prefix = "capacity.sources.#{backend}."

        [
          {prefix <> "reserve.percent", :reserve, get_in(source, ["reserve", "percent"]), get_in(base, ["reserve", "percent"])},
          {prefix <> "last_resort", :last_resort, source["last_resort"], base["last_resort"]}
          | Enum.map(@periods, &{prefix <> "limits.#{&1}", :limit, get_in(source, ["limits", &1]), get_in(base, ["limits", &1])})
        ]
      end)

    case Enum.find(global ++ per_source, &loosens?/1) do
      nil -> :ok
      {key, _kind, value, bound} -> {:error, loosening(key, layer, value, "L1", bound)}
    end
  end

  defp loosens?({_key, _kind, nil, _bound}), do: false
  defp loosens?({_key, _kind, _value, nil}), do: false
  defp loosens?({_key, :limit, value, bound}), do: value > bound
  defp loosens?({_key, :reserve, value, bound}), do: value < bound
  defp loosens?({_key, :last_resort, value, bound}), do: bound == true and value == false

  defp loosening(key, layer, value, bound_layer, bound) do
    {:invalid_workflow_config,
     "#{key}: #{@layer_names[layer]} (#{layer}) value #{inspect(value)} loosens the #{@layer_names[bound_layer]} (#{bound_layer}) value #{inspect(bound)}; a #{@layer_names[layer]} layer may only tighten capacity policy"}
  end

  defp merge_source(machine, project) do
    default = default_source()

    %{
      billing: machine["billing"] || default.billing,
      last_resort: machine["last_resort"] == true or project["last_resort"] == true,
      serves: machine["serves"] || default.serves,
      reserve: %{
        percent: max(get_in(machine, ["reserve", "percent"]) || 0, get_in(project, ["reserve", "percent"]) || 0),
        accounts: get_in(machine, ["reserve", "accounts"]) || :all
      },
      limits: merge_limits(machine["limits"], project["limits"])
    }
  end

  defp merge_limits(machine, project) do
    Map.new(@periods, fn period ->
      values = Enum.reject([(machine || %{})[period], (project || %{})[period]], &is_nil/1)
      {String.to_atom(period), if(values == [], do: nil, else: Enum.min(values))}
    end)
  end

  defp no_limits, do: Map.new(@periods, &{String.to_atom(&1), nil})

  defp plain(nil), do: %{"sources" => %{}, "limits" => %{}}

  defp plain(%_{} = capacity), do: plain(Map.from_struct(capacity))

  defp plain(capacity) do
    map = Map.new(capacity, fn {k, v} -> {to_string(k), v} end)
    Map.merge(map, %{"sources" => map["sources"] || %{}, "limits" => map["limits"] || %{}})
  end

  # --- runtime (L5) ------------------------------------------------------------

  @doc "The override path for an `aiur set` capacity key, or `:error`."
  @spec runtime_path(String.t()) :: {:ok, [String.t()]} | :error
  def runtime_path(key) do
    case Regex.run(@runtime_key, key) do
      [_, backend] -> {:ok, ["capacity", "sources", backend, "reserve", "percent"]}
      nil -> :error
    end
  end

  @doc """
  Refuses an `aiur set` reserve below the machine (L1) or project (L3) reserve.
  `config` is the workflow config the override is about to be merged into.
  """
  @spec check_runtime(String.t(), term(), map(), (-> {:ok, struct()} | {:error, term()})) :: :ok | {:error, term()}
  def check_runtime(key, value, config, machine_fun \\ &Settings.get/0) do
    with {:ok, path} <- runtime_path(key),
         :ok <- runtime_value(key, value),
         {:ok, machine} <- machine_capacity(machine_fun) do
      [_capacity, _sources, backend | _] = path

      bounds = [
        {"L3", get_in(config, path)},
        {"L1", get_in(plain(machine), ["sources", backend, "reserve", "percent"])}
      ]

      case Enum.find(bounds, fn {_layer, bound} -> is_number(bound) and value < bound end) do
        nil -> :ok
        {layer, bound} -> {:error, loosening(key, "L5", value, layer, bound)}
      end
    else
      :error -> :ok
      error -> error
    end
  end

  defp runtime_value(_key, value) when is_number(value) and value >= 0 and value <= 100, do: :ok
  defp runtime_value(key, _value), do: {:error, {:invalid_workflow_config, "#{key} must be a number from 0 to 100"}}

  defp machine_capacity(machine_fun) do
    case machine_fun.() do
      {:ok, machine} -> {:ok, machine.capacity}
      {:error, reason} -> {:error, {:invalid_workflow_config, "capacity: machine settings are unreadable (#{inspect(reason)})"}}
    end
  end

  # --- provenance ------------------------------------------------------------

  @doc "The built-in (L0) value of a `capacity.*` key path, or `:error` for an unknown key."
  @spec default_at([String.t()]) :: {:ok, term()} | :error
  def default_at(["default_burn_percent_per_hour"]), do: {:ok, nil}
  def default_at(["limits", period]) when period in @periods, do: {:ok, nil}
  def default_at(["sources", _backend | rest]), do: source_default(rest)
  def default_at(_path), do: :error

  defp source_default([]), do: {:ok, nil}
  defp source_default(["billing"]), do: {:ok, "unknown"}
  defp source_default(["last_resort"]), do: {:ok, false}
  defp source_default(["serves"]), do: {:ok, ["coding"]}
  defp source_default(["reserve", "percent"]), do: {:ok, 0}
  defp source_default(["reserve", "accounts"]), do: {:ok, nil}
  defp source_default(["limits", period]) when period in @periods, do: {:ok, nil}
  defp source_default(_path), do: :error

  @doc "The machine (L1) value at a `capacity.*` key path, or `nil`."
  @spec machine_value(struct() | map() | nil, [String.t()]) :: term()
  def machine_value(capacity, path), do: get_in(plain(capacity), path)

  @doc """
  Picks the effective layer for a `capacity.*` key from layers ordered highest
  first: the tightest value wins (largest reserve, smallest limit, any
  `last_resort: true`); machine-only keys keep the highest layer.
  """
  @spec pick([String.t()], [map(), ...]) :: {map(), [map()]}
  def pick(path, layers) do
    winner =
      case List.last(path) do
        "percent" -> Enum.max_by(layers, & &1.value, fn -> nil end)
        "last_resort" -> Enum.find(layers, hd(layers), &(&1.value == true))
        period when period in @periods -> Enum.min_by(layers, & &1.value, fn -> nil end)
        _ -> hd(layers)
      end

    {winner, List.delete(layers, winner)}
  end
end
