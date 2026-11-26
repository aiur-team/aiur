defmodule AiurWeb.Executor.BlockersPanel do
  @moduledoc false
  use Phoenix.Component

  alias Aiur.Instance.Roster.Presentation
  alias AiurWeb.Conversation.CommandCards

  @sources [{:commands, :command, "Executor Commands"}, {:asks, :ask, "Asks"}, {:fleet, :fleet, "Fleet blockers"}]

  attr(:snapshot, :map, required: true)
  attr(:decisions, :list, required: true)
  attr(:actions, :map, required: true)
  attr(:writable, :boolean, required: true)

  @spec panel(map()) :: Phoenix.LiveView.Rendered.t()
  def panel(assigns) do
    assigns =
      assigns
      |> assign(:sources, @sources)
      |> assign(:items, Enum.group_by(assigns.snapshot.items, & &1.kind))
      |> assign(:decisions_by_id, Map.new(assigns.decisions, &{&1.decision_id, &1}))
      |> assign(:closed, Enum.reject(assigns.decisions, & &1.open?))
      |> assign(:listed, assigns.snapshot.items |> Enum.filter(&(&1.kind == :command)) |> MapSet.new(& &1.id))

    ~H"""
    <section id="executor-blockers" aria-labelledby="executor-blockers-heading">
      <h2 id="executor-blockers-heading">Blockers</h2>
      <p :if={@snapshot.items == [] and Enum.all?(@snapshot.sources, fn {_source, status} -> status == :ok end)}>No Executor blockers</p>
      <section :for={{source, kind, label} <- @sources} id={"executor-blockers-#{source}"} aria-label={label}>
        <h3>{label}</h3>
        <p :if={match?({:unavailable, _}, @snapshot.sources[source])} role="status">
          Unavailable ({reason(@snapshot.sources[source])})
        </p>
        <div :for={item <- Map.get(@items, kind, [])}>
          <CommandCards.card
            :if={kind == :command and @decisions_by_id[item.id]}
            row={@decisions_by_id[item.id]}
            action={Map.get(@actions, item.id, %{})}
            writable={@writable and @decisions_by_id[item.id].open?}
            id_prefix="executor-"
          />
          <a :if={kind != :command or !@decisions_by_id[item.id]} href={item.link}>{item.title || item.id}</a>
          <small> · {age(item.age_ms)}</small>
          <p :if={kind == :ask}>Resolve with <code>aiur ask --done {item.id}</code></p>
        </div>
        <CommandCards.card
          :for={row <- @closed}
          :if={kind == :command and !MapSet.member?(@listed, row.decision_id)}
          row={row}
          action={Map.get(@actions, row.decision_id, %{})}
          writable={false}
          id_prefix="executor-"
        />
      </section>
    </section>
    """
  end

  defp age(nil), do: "age unknown"
  defp age(ms), do: Presentation.age(ms)

  defp reason({:unavailable, reason}) when is_atom(reason), do: reason
  defp reason({:unavailable, {kind, _detail}}) when is_atom(kind), do: kind
  defp reason({:unavailable, {kind, _path, _line, detail}}) when is_atom(kind) and is_atom(detail), do: "#{kind}: #{detail}"
  defp reason({:unavailable, _}), do: :unknown
end
