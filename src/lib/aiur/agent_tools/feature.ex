defmodule Aiur.AgentTools.Feature do
  @moduledoc "Feature operations with daemon-bound attribution and operator-only scope controls."
  @behaviour Aiur.AgentTools.Handler

  alias Aiur.AgentTools.{Args, Errors, Response}

  @keys ~w(op slug ids epic epics lane lanes move remove label hue backfill)
  @operations ~w(create add remove also show)
  @fields %{
    "create" => ~w(op slug label hue epics lanes backfill),
    "add" => ~w(op slug ids epic lane move backfill),
    "remove" => ~w(op slug ids backfill),
    "also" => ~w(op slug ids remove backfill),
    "show" => ~w(op slug backfill)
  }

  @impl true
  def tools, do: ["aiur_feature"]

  @impl true
  def specs do
    [
      %{
        "name" => "aiur_feature",
        "description" =>
          "Create features, batch owning membership or also-affects links, and show feature records. A feature sits in at most one epic; the lanes it belongs to are its technical columns. Actor is fixed by the daemon; baseline and edit are operator-only.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["op"],
          "properties" => %{
            "op" => %{"type" => "string", "enum" => @operations},
            "slug" => %{"type" => "string"},
            "label" => %{"type" => "string"},
            "hue" => %{"type" => "integer", "minimum" => 0, "maximum" => 359},
            "ids" => %{"type" => "array", "items" => %{"type" => "integer", "minimum" => 1, "maximum" => 2_147_483_647}, "minItems" => 1, "maxItems" => 200},
            "lane" => %{"type" => "string", "description" => "Lane key a membership joins; the deprecated name is epic."},
            "epic" => %{"type" => "string", "description" => "Deprecated alias of lane."},
            "lanes" => %{
              "type" => "array",
              "description" => "Lanes the feature spans. The deprecated name is epics.",
              "items" => %{"type" => "object", "additionalProperties" => false, "required" => ["key", "label"], "properties" => %{"key" => %{"type" => "string"}, "label" => %{"type" => "string"}}}
            },
            "epics" => %{
              "type" => "array",
              "description" => "Deprecated alias of lanes.",
              "items" => %{"type" => "object", "additionalProperties" => false, "required" => ["key", "label"], "properties" => %{"key" => %{"type" => "string"}, "label" => %{"type" => "string"}}}
            },
            "move" => %{"type" => "boolean"},
            "remove" => %{"type" => "boolean"},
            "backfill" => %{"type" => "boolean"}
          }
        }
      }
    ]
  end

  @impl true
  def execute("aiur_feature", arguments, opts) do
    with {:ok, normalized} <- normalize(arguments),
         writer when is_function(writer, 1) <- opts[:feature_writer],
         {:ok, envelope} <- writer.(normalized) do
      Response.build(true, Jason.encode!(Response.jsonable(envelope)))
    else
      {:usage, message} -> Response.failure(Errors.payload({:invalid_feature_arguments, message}))
      {:error, reason} -> Response.failure(Errors.payload(reason))
      _ -> Response.failure(Errors.payload(:feature_writer_unavailable))
    end
  end

  @spec normalize(term()) :: {:ok, map()} | {:error, term()}
  def normalize(args) when is_map(args) do
    with true <- Enum.all?(Map.keys(args), &(&1 in @keys)),
         {:ok, op} <- Args.string(args, "op", :invalid_feature_arguments),
         :ok <- allowed_operation(op, args),
         true <- Enum.all?(Map.keys(args), &(&1 in @fields[op])),
         true <- valid_values?(args, op),
         {:ok, normalized} <- alias_lanes(Map.new(args, fn {key, value} -> {String.to_existing_atom(key), value} end)) do
      normalized = Map.put(normalized, :op, String.to_existing_atom(op))
      normalized = if Map.has_key?(normalized, :epics), do: Map.update!(normalized, :epics, &normalize_epics/1), else: normalized
      {:ok, if(Map.has_key?(normalized, :ids), do: Map.update!(normalized, :ids, &Enum.uniq/1), else: normalized)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_feature_arguments}
    end
  end

  def normalize(_), do: {:error, :invalid_feature_arguments}

  defp allowed_operation(op, _args) when op in ["baseline", "edit"], do: {:error, {:agent_cannot_use_feature_op, op}}
  defp allowed_operation(op, %{"backfill" => true}) when op != "add", do: {:error, {:backfill_cannot_use_feature_op, op}}
  defp allowed_operation(op, _args) when op in @operations, do: :ok
  defp allowed_operation(_, _), do: {:error, :invalid_feature_arguments}

  defp normalize_epics(epics), do: Enum.map(epics, fn epic -> %{key: epic["key"], label: epic["label"]} end)

  # `lane` and `lanes` are the current names; `epic` and `epics` stay accepted as
  # the deprecated spelling of the same field.
  defp alias_lanes(args) do
    with {:ok, args} <- alias_lane(args, :lane, :epic), do: alias_lane(args, :lanes, :epics)
  end

  defp alias_lane(args, old_key, new_key) do
    cond do
      not Map.has_key?(args, old_key) -> {:ok, args}
      Map.has_key?(args, new_key) -> {:error, {:conflicting_feature_arguments, old_key, new_key}}
      true -> {:ok, args |> Map.put(new_key, Map.fetch!(args, old_key)) |> Map.delete(old_key)}
    end
  end

  defp valid_values?(args, op) do
    valid_strings?(args) and valid_flags?(args) and required_fields?(args, op) and valid_hue?(args) and valid_ids?(args, op) and valid_epics?(args)
  end

  defp valid_strings?(args), do: Enum.all?(~w(slug label epic lane), fn key -> not Map.has_key?(args, key) or (is_binary(args[key]) and String.trim(args[key]) != "") end)
  defp valid_flags?(args), do: Enum.all?(~w(move remove backfill), fn key -> not Map.has_key?(args, key) or is_boolean(args[key]) end)
  defp required_fields?(args, op), do: (op == "show" or Map.has_key?(args, "slug")) and (op != "create" or Map.has_key?(args, "label"))
  defp valid_hue?(args), do: not Map.has_key?(args, "hue") or (is_integer(args["hue"]) and args["hue"] in 0..359)

  defp valid_ids?(args, op) when op in ["add", "remove", "also"] do
    ids = args["ids"]
    is_list(ids) and length(ids) in 1..200 and Enum.all?(ids, &(is_integer(&1) and &1 in 1..2_147_483_647))
  end

  defp valid_ids?(_, _), do: true

  defp valid_epics?(args) when is_map(args) do
    lanes = Map.get(args, "lanes", Map.get(args, "epics"))

    is_nil(lanes) or (is_list(lanes) and Enum.all?(lanes, &valid_lane?/1))
  end

  # One clause on purpose: dialyzer proves the element type carries "key" and
  # "label", so a pattern clause plus a fallback reads as unreachable even
  # though a malformed lane can still arrive from JSON.
  defp valid_lane?(lane) do
    is_map(lane) and map_size(lane) == 2 and valid_lane_fields?(Map.get(lane, "key"), Map.get(lane, "label"))
  end

  defp valid_lane_fields?(key, label) do
    is_binary(key) and key != "" and is_binary(label) and String.trim(label) != ""
  end
end
