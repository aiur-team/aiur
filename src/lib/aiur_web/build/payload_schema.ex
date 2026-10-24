defmodule AiurWeb.Build.PayloadSchema do
  @moduledoc false
  alias AiurWeb.Build.ConversationPayload
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
      "start_src" => enum(~w(label dispatch unknown)),
      "end" => nullable(:integer),
      "created" => nullable(:integer),
      "status" => enum(~w(done failed not_planned closed running queued open)),
      "pct" => nullable({:range, 0, 100}),
      "agent" =>
        nullable(
          object(
            %{
              "model" => nullable(:model),
              "name" => nullable({:short_string, 64}),
              "state" =>
                nullable(
                  enum(~w(active error retrying retries command paused parked usage_limited ci_wait merge-queued ci-red body-fix paused-usage-limit paused-decision paused-agent blocked handed-off))
                ),
              "pause" => nullable(enum(~w(usage_limit_exhausted ci_wait))),
              "resume_at" => nullable(:integer),
              "effort" => nullable(enum(~w(none minimal low medium high xhigh max)))
            },
            ~w(pause resume_at)
          )
        ),
      "est" => nullable(:number),
      "override" => nullable(object(%{"hours" => :number, "reason" => :string, "by" => nullable(:string), "at" => nullable(:integer)})),
      "added" => :boolean,
      "deps" => list(:id),
      "children" => list(:id),
      "dep_states" => {:dictionary, enum(~w(cleared blocking terminal_unsatisfied unknown))},
      "deps_missing" => nullable(:nonnegative),
      "wave" => nullable(:integer),
      "qpos" => nullable(:nonnegative),
      "cue" => nullable(object(cue(), ["unknown"])),
      "pr" => nullable(object(%{"num" => :positive, "state" => enum(~w(open merged closed))}))
    }
  end

  @spec history() :: map()
  def history, do: %{"from" => nullable(:integer), "more" => :boolean, "total" => nullable(:nonnegative), "undated" => nullable(:nonnegative), "tz" => :string}

  @spec blocks() :: map()
  def blocks do
    %{
      "capacity" => object(%{"max" => nullable(:positive), "observed_at" => nullable(:integer), "stale" => nullable(:boolean)}),
      "writable" => :boolean,
      "repo" => nullable(object(%{"url" => :string})),
      "epics" => {:dictionary, object(epic(), ~w(general feature temp unsorted))},
      "features" =>
        {:dictionary,
         object(%{
           "key" => :string,
           "label" => :string,
           "hue" => :number,
           "epics" => list(:string),
           "from" => nullable(:integer),
           "to" => nullable(:integer),
           "stats" => nullable(object(feature_stats()))
         })},
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

  def message("ticket"), do: Map.merge(Map.put(Map.delete(envelope(), "now"), "row", :row), control_fields())
  def message("control"), do: Map.merge(%{"v" => {:literal, 1}, "kind" => {:literal, "control"}, "id" => :id}, control_fields())

  def message("error"),
    do: %{
      "v" => {:literal, 1},
      "kind" => {:literal, "error"},
      "reason" => enum(~w(invalid_params unavailable invalid_data read_only not_found throttled timeout index_not_running read_failed epic_config_unavailable settings_loading))
    }

  def message(kind), do: ConversationPayload.message(kind)

  @spec usage(String.t()) :: map() | nil
  def usage("locked"), do: %{"state" => {:literal, "locked"}, "accessible_name" => :string, "authentication_path" => :string, "reason" => :string}
  def usage("unavailable"), do: %{"state" => {:literal, "unavailable"}, "observed_at" => nullable(:integer), "reason" => :string}

  def usage("authorized"),
    do: %{
      "state" => {:literal, "authorized"},
      "observed_at" => nullable(:integer),
      "apis" => list(object(provider(), ~w(lines icon stale observed_at snapshot_observed_at note))),
      "providers" => list(object(provider(), ~w(lines icon stale observed_at snapshot_observed_at note)))
    }

  def usage(_state), do: nil

  defp control_fields do
    %{
      "control" =>
        nullable(
          object(%{
            "action" => nullable(enum(~w(pause resume))),
            "state" => enum(~w(enabled pending disabled)),
            "title" => :string,
            "status" => nullable(object(%{"label" => :string, "tone" => enum(~w(pending applied warning error)), "retry" => :boolean}))
          })
        ),
      "chat" => nullable(:string),
      "by_you_at" => nullable(:integer)
    }
  end

  defp feature_stats do
    %{
      "total" => :nonnegative,
      "done" => nullable(:nonnegative),
      "done_min" => :nonnegative,
      "pct" => nullable({:integer_range, 0, 100}),
      "pct_min" => nullable({:integer_range, 0, 100}),
      "orig" => :nonnegative,
      "added" => :nonnegative,
      "baseline" => :boolean,
      "spark" => nullable(list(:nonnegative)),
      "also" => :nonnegative,
      "reasons" => list(enum(~w(complexity no_weight progress status)))
    }
  end

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
      "none" => :boolean,
      "lines" => nullable(list(object(line()))),
      "icon" => nullable(enum(~w(github bars))),
      "stale" => :boolean,
      "observed_at" => nullable(:integer),
      "snapshot_observed_at" => nullable(:integer),
      "note" => nullable(:string)
    }
  end

  defp window, do: %{"acc" => list(nullable({:range, 0, 100})), "reset_at" => nullable(:integer), "win" => nullable(:string)}
  defp line, do: Map.merge(window(), %{"tag" => :string, "tip" => list({:pair, :string}), "hold_until" => nullable(:integer)})
  defp envelope, do: %{"v" => {:literal, 1}, "kind" => enum(~w(snapshot diff earlier ticket)), "epoch" => :string, "generation" => :nonnegative, "now" => :integer}

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

  defp sources do
    standard = Map.new(~w(history features queue agents index estimates), &{&1, object(source())})
    Map.put(standard, "open_tickets", object(Map.put(source(), "truncated", :boolean)))
  end

  defp source, do: %{"state" => enum(~w(ok stale incomplete unavailable disabled unsupported)), "observed_at" => nullable(:integer), "reason" => nullable(:string)}

  defp cue,
    do: %{
      "held" => nullable(:string),
      "promoted" => nullable(:integer),
      "wait" => nullable(:nonnegative),
      "waitAny" => :boolean,
      "failed" => nullable(object(%{"by" => :positive, "blocks" => list(:positive)})),
      "blockedChain" => :boolean,
      "unknown" => :boolean
    }

  defp object(fields, optional \\ []), do: {:object, fields, optional}
  defp nullable(type), do: {:nullable, type}
  defp list(type), do: {:list, type}
  defp enum(values), do: {:enum, values}
end
