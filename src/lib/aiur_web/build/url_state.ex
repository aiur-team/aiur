defmodule AiurWeb.Build.URLState do
  @moduledoc "Validated, canonical build-home URL state shared by navigation and hook events."
  alias AiurWeb.OperatorControlCenter.UnitsURL

  @views ~w(gantt list)
  @spans [1, 2, 3, 5, 7, 10, 14, 21, 30]
  @tstates ["merged", "failed", "in progress", "queued", "held", "blocked", "open", "not planned"]
  @astates ~w(active error retries command paused parked none)
  # ponytail: C5-T01/C6-T01 share this slug shape; widen together if their slugs change.
  @slug ~r/\A[A-Za-z0-9._-]{1,64}\z/
  @model_key ~r/\A[a-z0-9][a-z0-9._-]{0,31}\z/
  @agent_presets %{active: ["active"], alert: ~w(error retries command), paused: ~w(paused parked), stuck: ~w(error retries command)}
  @ticket_presets %{active: ["in progress"], alert: ["in progress"], paused: ["in progress"], stuck: ["in progress"], queued: ~w(queued held blocked), finished: ~w(merged failed)}
  @defaults %{view: "graph", span: 1, feature: nil, fmode: "focus", epic: [], model: [], tstate: [], astate: [], live_min: false, trees: false, ticket: nil}

  @type t :: %{
          view: String.t(),
          span: pos_integer(),
          feature: String.t() | nil,
          fmode: String.t(),
          epic: [String.t()],
          model: [String.t()],
          tstate: [String.t()],
          astate: [String.t()],
          live_min: boolean(),
          trees: boolean(),
          ticket: String.t() | nil
        }

  @spec defaults() :: t()
  def defaults, do: @defaults

  @spec parse(map()) :: t()
  def parse(params) do
    feature = valid_string(params["feature"], @slug)

    %{
      view: if(params["view"] in @views, do: params["view"], else: "graph"),
      span: span(params["span"]),
      feature: feature,
      fmode: if(feature && params["fmode"] == "compact", do: "compact", else: "focus"),
      epic: items(params["epic"], &(valid_string(&1, @slug) != nil)),
      model: items(params["model"], &(&1 != "none" and valid_string(&1, @model_key) != nil)),
      tstate: items(params["tstate"], &(&1 in @tstates)),
      astate: items(params["astate"], &(&1 in @astates)),
      live_min: params["live"] == "min",
      trees: params["trees"] == "1",
      ticket: ticket(params["ticket"])
    }
  end

  @spec to_query(t()) :: String.t()
  def to_query(state) do
    [
      {"view", if(state.view != "graph", do: state.view)},
      {"trees", if(state.trees, do: "1")},
      {"live", if(state.live_min, do: "min")},
      {"span", if(state.span != 1, do: Integer.to_string(state.span))},
      {"feature", state.feature},
      {"fmode", if(state.feature && state.fmode == "compact", do: "compact")},
      {"epic", Enum.join(state.epic, ",")},
      {"model", Enum.join(state.model, ",")},
      {"tstate", Enum.join(state.tstate, ",")},
      {"astate", Enum.join(state.astate, ",")},
      {"ticket", state.ticket}
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> URI.encode_query()
    |> String.replace("%2C", ",")
  end

  @spec legacy?(map()) :: boolean()
  def legacy?(params), do: Enum.any?(~w(v scope conditions), &Map.has_key?(params, &1))

  @spec legacy_preset(map()) :: %{optional(String.t()) => String.t()}
  def legacy_preset(params) do
    case UnitsURL.decode(params) do
      %{scope: :unfinished, conditions: []} -> %{"tstate" => "in progress,queued,held,blocked"}
      %{conditions: []} -> %{}
      %{conditions: conditions} -> condition_preset(conditions)
    end
  end

  defp condition_preset(conditions) do
    if Enum.any?(conditions, &(&1 in [:queued, :finished])) do
      selected = Enum.flat_map(conditions, &Map.fetch!(@ticket_presets, &1))
      %{"tstate" => @tstates |> Enum.filter(&(&1 in selected)) |> Enum.join(",")}
    else
      %{"astate" => conditions |> Enum.flat_map(&Map.fetch!(@agent_presets, &1)) |> Enum.uniq() |> Enum.join(",")}
    end
  end

  defp valid_string(value, pattern) when is_binary(value) do
    if Regex.match?(pattern, value), do: value
  end

  defp valid_string(_value, _pattern), do: nil

  defp span(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n in @spans -> n
      _ -> 1
    end
  end

  defp span(_value), do: 1

  defp ticket(value) do
    with value when is_binary(value) <- valid_string(value, ~r/\A[0-9]{1,10}\z/),
         n when n > 0 <- String.to_integer(value) do
      Integer.to_string(n)
    else
      _ -> nil
    end
  end

  defp items(value, valid?) when is_binary(value) do
    value |> String.splitter(",") |> Stream.filter(valid?) |> Stream.uniq() |> Enum.take(32)
  end

  defp items(_value, _valid?), do: []
end
