defmodule AiurWeb.Build.PayloadSchema do
  @moduledoc false
  # Cohesive schema definitions: required keys are literal; only epic flags are optional.
  @spec row() :: map()
  def row do
    %{
      "id" => :id,
      "num" => nullable(:positive),
      "title" => :string,
      "type" => enum(~w(bug feature chore docs)),
      "epic" => nullable(:string),
      "feature" => nullable(:string),
      "also" => list(:string),
      "cx" => nullable({:integer_range, 1, 5}),
      "pts" => nullable(:nonnegative),
      "sec" => enum(~w(hist now plan nq)),
      "ord" => :integer,
      "start" => nullable(:integer),
      "end" => nullable(:integer),
      "created" => nullable(:integer),
      "status" => enum(~w(done failed not_planned closed running queued open)),
      "pct" => nullable({:range, 0, 100}),
      "agent" => nullable(object(%{"model" => :model, "state" => nullable(enum(~w(active error retries command paused parked))), "effort" => nullable(enum(~w(low medium high)))})),
      "est" => nullable(:number),
      "override" => nullable(object(%{"hours" => :number, "reason" => :string, "by" => nullable(:string), "at" => nullable(:integer)})),
      "added" => :boolean,
      "deps" => list(:id),
      "wave" => nullable(:integer),
      "qpos" => nullable(:nonnegative),
      "cue" => nullable(object(cue())),
      "pr" => nullable(object(%{"num" => :positive, "state" => enum(~w(open merged closed))}))
    }
  end

  @spec history() :: map()
  def history, do: %{"from" => nullable(:integer), "more" => :boolean, "total" => nullable(:nonnegative), "undated" => nullable(:nonnegative), "tz" => :string}

  @spec blocks() :: map()
  def blocks do
    %{
      "writable" => :boolean,
      "repo" => nullable(object(%{"url" => :string})),
      "epics" => {:dictionary, object(epic(), ~w(general feature temp unsorted))},
      "features" => {:dictionary, object(%{"key" => :string, "label" => :string, "hue" => :number, "epics" => list(:string), "from" => nullable(:integer), "to" => nullable(:integer)})},
      "order" => list(:string),
      "counts" => nullable({:dictionary, :nonnegative}),
      "history" => object(history()),
      "sources" => object(sources()),
      "usage" => :usage,
      "daemon" => object(%{"state" => enum(~w(live stale offline unknown)), "heartbeat_at" => nullable(:integer), "observed_at" => nullable(:integer)})
    }
  end

  @spec message(String.t()) :: map() | nil
  def message("snapshot"), do: Map.merge(envelope(), Map.put(blocks(), "sections", object(Map.new(~w(hist now plan nq), &{&1, list(:row)}))))
  def message("diff"), do: Map.merge(envelope(), %{"upsert" => list(:row), "remove" => list(:id), "set" => object(blocks(), Map.keys(blocks()))})
  def message("earlier"), do: Map.merge(Map.delete(envelope(), "now"), %{"rows" => list(:row), "history" => object(history())})
  def message("error"), do: %{"v" => {:literal, 1}, "kind" => {:literal, "error"}, "reason" => enum(~w(invalid_params unavailable read_only not_found))}
  def message(_kind), do: nil

  @spec usage(String.t()) :: map() | nil
  def usage("locked"), do: %{"state" => {:literal, "locked"}, "accessible_name" => :string, "authentication_path" => :string, "reason" => :string}
  def usage("unavailable"), do: %{"state" => {:literal, "unavailable"}, "observed_at" => nullable(:integer), "reason" => :string}
  def usage("authorized"), do: %{"state" => {:literal, "authorized"}, "observed_at" => nullable(:integer), "apis" => list(object(provider())), "providers" => list(object(provider()))}
  def usage(_state), do: nil

  defp provider do
    %{
      "name" => :string,
      "logo" => nullable(:string),
      "mono" => nullable(:string),
      "hue" => nullable(:number),
      "tag" => nullable(:string),
      "accounts" => nullable(list(:string)),
      "session" => nullable(object(window())),
      "weekly" => nullable(object(window())),
      "credits" => nullable(object(%{"pct" => nullable({:range, 0, 100}), "left" => :string, "tip" => list({:pair, :string})})),
      "none" => :boolean
    }
  end

  defp window, do: %{"acc" => list(nullable({:range, 0, 100})), "reset_at" => nullable(:integer), "win" => :string}
  defp envelope, do: %{"v" => {:literal, 1}, "kind" => enum(~w(snapshot diff earlier)), "epoch" => :string, "generation" => :nonnegative, "now" => :integer}

  defp epic,
    do: %{
      "key" => :string,
      "label" => :string,
      "hue" => :number,
      "icon" => enum(~w(bug pen server docs layers unsorted)),
      "general" => :boolean,
      "feature" => :string,
      "temp" => :boolean,
      "unsorted" => :boolean
    }

  defp sources,
    do:
      Map.new(
        ~w(history features queue agents index),
        &{&1, object(%{"state" => enum(~w(ok stale incomplete unavailable disabled)), "observed_at" => nullable(:integer), "reason" => nullable(:string)})}
      )

  defp cue,
    do: %{
      "held" => nullable(:string),
      "promoted" => nullable(:integer),
      "wait" => nullable(:nonnegative),
      "waitAny" => :boolean,
      "failed" => nullable(object(%{"by" => :positive, "blocks" => list(:positive)})),
      "blockedChain" => :boolean
    }

  defp object(fields, optional \\ []), do: {:object, fields, optional}
  defp nullable(type), do: {:nullable, type}
  defp list(type), do: {:list, type}
  defp enum(values), do: {:enum, values}
end
