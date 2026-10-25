defmodule AiurWeb.Build.ConversationPayload do
  @moduledoc false

  alias AiurWeb.Build.Payload

  @states ~w(live ended known_empty stale unavailable restart_unknown not_retained)
  @text {:short_string, 8_001}

  @spec message(String.t()) :: map() | nil
  def message("conversation") do
    Map.merge(base("conversation"), %{
      "reset" => :boolean,
      "state" => {:enum, @states},
      "reason" => {:nullable, :string},
      "live" => :boolean,
      "observed_at" => {:nullable, :integer},
      "entries" => {:list, :conversation_entry},
      "before" => {:nullable, :string},
      "more" => :boolean,
      "note" => {:nullable, {:enum, ~w(legacy_log remote_window live_window)}},
      "evicted" => :nonnegative,
      "composer" => {:nullable, {:enum, ~w(ready ambiguous)}}
    })
  end

  def message("send") do
    Map.merge(base("send"), %{
      "ok" => :boolean,
      "request_id" => {:nullable, :integer},
      "entry_id" => {:nullable, {:short_string, 256}},
      "text" => {:nullable, @text},
      "at" => {:nullable, :integer},
      "reason" =>
        {:nullable,
         {:enum, ~w(outcome_unknown not_queued no_running_agent empty_message message_too_long max_concurrent_agents_reached globally_paused unavailable timeout ambiguous_identifier error)}},
      "unknown" => :boolean,
      "message" => {:nullable, :string}
    })
  end

  def message("send-status"),
    do: Map.merge(base("send-status"), %{"request_id" => :integer, "status" => {:enum, ~w(queued delivered failed superseded unconfirmed)}})

  def message("conversation-earlier"),
    do: Map.merge(base("conversation-earlier"), %{"entries" => {:list, :conversation_entry}, "before" => {:nullable, :string}, "more" => :boolean})

  def message("conversation-append"), do: Map.merge(base("conversation-append"), %{"entries" => {:list, :conversation_entry}, "gap" => :boolean})

  def message("conversation-state"),
    do: Map.merge(base("conversation-state"), %{"state" => {:enum, @states}, "live" => :boolean, "observed_at" => {:nullable, :integer}})

  def message("ok"), do: %{"v" => {:literal, 1}, "kind" => {:literal, "ok"}}
  def message(_kind), do: nil

  @spec entry(String.t()) :: {map(), [String.t()]} | nil
  def entry(kind) when kind in ~w(say op sys), do: {Map.put(entry_base(kind), "text", @text), []}

  def entry("tool"),
    do: {Map.merge(entry_base("tool"), %{"name" => @text, "arg" => @text, "res" => @text, "bad" => :boolean}), ["bad"]}

  def entry("ev") do
    {Map.merge(entry_base("ev"), %{
       "ev" => {:enum, ~w(dep commit prog pr review comment merge fail cmd you)},
       "label" => @text,
       "sub" => @text,
       "go" => {:nullable, :string},
       "pct" => {:nullable, {:integer_range, 0, 100}}
     }), ~w(sub go pct)}
  end

  def entry("diff"),
    do: {Map.merge(entry_base("diff"), %{"file" => @text, "lines" => {:list, {:pair, @text}}, "add" => :nonnegative, "del" => :nonnegative}), []}

  def entry(_kind), do: nil

  @spec view(String.t(), map(), boolean()) :: map()
  def view(id, view, reset \\ false) do
    %{
      v: 1,
      kind: "conversation",
      id: id,
      reset: reset,
      state: view.state,
      reason: view[:reason],
      live: view.live?,
      observed_at: millis(view[:observed_at]),
      entries: view.entries,
      before: view[:before],
      more: view.more?,
      note: view[:note],
      evicted: view[:evicted] || 0,
      composer: nil
    }
    |> Payload.scrub()
  end

  @spec millis(DateTime.t() | integer() | nil) :: integer() | nil
  def millis(%DateTime{} = time), do: DateTime.to_unix(time, :millisecond)
  def millis(time) when is_integer(time), do: time
  def millis(_time), do: nil

  defp base(kind), do: %{"v" => {:literal, 1}, "kind" => {:literal, kind}, "id" => :conversation_id}
  defp entry_base(kind), do: %{"id" => {:short_string, 256}, "k" => {:literal, kind}, "at" => {:nullable, :integer}, "cursor" => {:short_string, 256}}
end
