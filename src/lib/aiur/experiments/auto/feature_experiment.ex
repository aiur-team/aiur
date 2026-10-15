defmodule Aiur.Experiments.Auto.FeatureExperiment do
  @moduledoc false
  alias Aiur.Experiments
  alias Aiur.Experiments.Auto.{Creator, Line, LiveSignal, Notifier}
  alias Aiur.Experiments.{Reader, Snapshot, Spec}

  @spec apply_effect(String.t(), map(), atom(), map(), DateTime.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def apply_effect(number, state, :arm, _config, _now, opts) do
    line = %Line{
      source: :feature,
      key: "auto:feature:#{number}",
      at: time(state["before_end"]),
      before_window: {time(state["before_start"]), time(state["before_end"])},
      evidence: %{armed: true, epic: number, baseline_coverage: state["baseline_coverage"]}
    }

    with {:ok, _created} <- Creator.create(line, Keyword.get(opts, :creator, Creator)),
         {:ok, spec} <- find(line.key),
         :ok <- Notifier.notify(spec, "preregister", Keyword.get(opts, :notifier, Notifier)) do
      {:ok, Map.put(state, "experiment_id", spec["id"])}
    end
  end

  def apply_effect(_number, state, :freeze, _config, _now, _opts) do
    id = state["experiment_id"]

    with {:ok, spec, false} <- Reader.spec(id),
         windows = Map.put(spec["windows"], "before", before(state)),
         design = put_in(spec["design"], ["change", "time"], state["before_end"]),
         {:ok, _spec} <- amend(id, spec, %{"windows" => windows, "design" => design}),
         :ok <- freeze_once(id, before(state)) do
      {:ok, state}
    end
  end

  def apply_effect(_number, state, :resolve_live, config, now, opts) do
    case LiveSignal.resolve(state["last_merge"], config, now, opts) do
      {:ok, live} -> set_line(state, live, config)
      :pending -> {:ok, state}
      error -> error
    end
  end

  def apply_effect(_number, state, :cancel, _config, _now, opts) do
    id = state["experiment_id"]

    with {:ok, spec, false} <- Reader.spec(id),
         {:ok, updated} <- amend(id, spec, %{"status" => "cancelled"}),
         :ok <- Notifier.notify(Spec.to_map(updated), "cancelled", Keyword.get(opts, :notifier, Notifier)) do
      {:ok, state}
    end
  end

  def apply_effect(_number, state, :scope, _config, now, _opts) do
    id = state["experiment_id"]
    key = "post_line_scope:" <> Jason.encode!(state["member_numbers"])

    with {:ok, detail} <- Experiments.fetch(id) do
      if Enum.any?(detail.annotations, &(&1["scope_key"] == key)) do
        {:ok, state}
      else
        with :ok <- Experiments.annotate(id, %{kind: "note", at: DateTime.to_iso8601(now), reason: "post-line scope change", scope_key: key}, "auto_feature"), do: {:ok, state}
      end
    end
  end

  defp set_line(state, live, config) do
    id = state["experiment_id"]
    at = time(live["at"])

    with {:ok, spec, false} <- Reader.spec(id) do
      evidence =
        Map.merge(spec["design"]["change"]["evidence"], live)
        |> Map.merge(%{"armed" => false, "merge_sha" => state["last_merge"]["sha"], "excluded" => %{"start" => state["first_merge"]["at"], "end" => live["at"]}})

      design = spec["design"] |> put_in(["change", "time"], live["at"]) |> put_in(["change", "evidence"], evidence)
      windows = Map.put(spec["windows"], "after", %{"start" => live["at"], "end" => DateTime.to_iso8601(DateTime.add(at, config.after_days * 86_400))})

      with {:ok, _updated} <- amend(id, spec, %{"design" => design, "windows" => windows, "status" => "active"}) do
        {:ok, Map.merge(state, %{"phase" => "line_set", "live" => live})}
      end
    end
  end

  defp freeze_once(id, window) do
    with {:ok, snapshot} <- Snapshot.latest(id, "before") do
      if snapshot && snapshot["window"] == window do
        :ok
      else
        case Experiments.freeze(id, "before", reason: "first feature member merge") do
          {:ok, _snapshot} -> :ok
          error -> error
        end
      end
    end
  end

  defp amend(id, spec, changes) do
    if Enum.all?(changes, fn {key, value} -> spec[key] == value end), do: Spec.new(spec), else: Experiments.amend(id, changes, "auto_feature")
  end

  defp find(key) do
    with {:ok, ids} <- Experiments.Paths.ids() do
      result =
        Enum.find_value(ids, fn id ->
          case Reader.spec(id) do
            {:ok, %{"key" => ^key} = spec, false} -> spec
            _other -> nil
          end
        end)

      if result, do: {:ok, result}, else: {:error, :feature_experiment_missing}
    end
  end

  defp before(state), do: %{"start" => state["before_start"], "end" => state["before_end"]}
  defp time(value), do: value |> DateTime.from_iso8601() |> elem(1)
end
