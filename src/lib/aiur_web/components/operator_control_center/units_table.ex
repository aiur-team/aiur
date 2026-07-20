defmodule AiurWeb.OperatorControlCenter.UnitsTable do
  @moduledoc false

  use Phoenix.Component

  alias Aiur.BuildOrder.Bounded
  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.{DecisionPath, UnitsControlPolicy, UnitsPresenter}

  attr(:view, :map, required: true)
  attr(:now, :any, required: true)
  attr(:controls, :map, default: %{})
  attr(:writable, :boolean, default: false)

  @spec units_table(map()) :: Phoenix.LiveView.Rendered.t()
  def units_table(assigns) do
    assigns =
      assigns
      |> assign(:rows, display_rows(assigns.view))
      |> assign(:status, Map.get(assigns.view, :status, :loading))
      |> assign(:message, Map.get(assigns.view, :message))

    ~H"""
    <div class="units-results" aria-describedby="units-filter-note">
      <div :if={@status == :loading} class="units-state empty-state">Loading Units…</div>

      <div :if={@status == :unavailable} class="units-state error-card" role="alert">
        <h3>Units unavailable</h3>
        <p>{@message || "The Units catalog cannot be read right now."}</p>
      </div>

      <div :if={@status == :empty} class="units-state empty-state">
        {@message || "No units have been observed in this run."}
      </div>

      <div :if={@status == :stale} class="units-state readonly-banner" role="status">
        <span aria-hidden="true">◉</span>
        <span><b>Units may be stale.</b> {@message || "Showing the last-known catalog."}</span>
      </div>

      <div :if={@view[:truncated?]} class="units-state readonly-banner" role="status">
        <span aria-hidden="true">◉</span>
        <span><b>Units catalog is partial.</b> Counts are lower bounds for the bounded membership prefix.</span>
      </div>

      <div :if={@view[:zero_result?]} class="units-state empty-state filtered-empty">
        <p>No units match this valid scope and condition selection.</p>
        <button type="button" class="btn ghost units-reset" phx-click="reset-units-filters">Reset Units filters</button>
      </div>

      <div :if={@rows != []} class="units-table-wrap">
        <table class="units-table">
          <caption class="sr-only">Units catalog with execution facts, current evidence, and named actions</caption>
          <thead>
            <tr>
              <th class="ut-col-id">ID</th>
              <th class="ut-col-unit">Unit</th>
              <th class="ut-col-ticket">Ticket</th>
              <th class="ut-col-latest">Latest</th>
              <th class="ut-col-cmd">Command</th>
            </tr>
          </thead>
          <tbody id="units-rows">
            <tr
              :for={{row, token, github_url} <- @rows}
              id={"unit-#{token}"}
              class={["units-row", row_tone(row)]}
              data-unit-token={token}
            >
              <td data-label="ID" class="ut-id-cell">
                <span :if={row_tone(row)} class={["ut-alert", row_tone(row)]} aria-hidden="true">△</span>
                <span class="ut-id-num mono num">{id_number(row.identity)}</span>
              </td>

              <td data-label="Unit" class="ut-unit-cell">
                <div class="ut-pill-row">
                  <span class={["u-pill", "u-agent", agent_class(row.agent_family)]}>{agent_label(row.agent_family)}</span>
                  <span :if={is_integer(row.complexity)} class="u-pill u-cx">Cx:{row.complexity}</span>
                </div>
                <div class="ut-pill-row">
                  <span :if={present?(model_label(row))} class="u-pill u-model">{model_label(row)}</span>
                  <span class={["u-pill", "u-prio", priority_class(row)]}>{priority_label(row)}</span>
                </div>
              </td>

              <td data-label="Ticket" class="ut-ticket-cell">
                <div class="ut-title">{known(row.title, "Title unknown")}</div>
                <span :if={present?(row.build_lane)} class={["u-lane", lane_class(row.build_lane)]}>
                  <span class="u-lane-dot" aria-hidden="true"></span>{String.upcase(row.build_lane)}
                </span>
              </td>

              <td data-label="Latest" class="ut-latest-cell">
                <div class="ut-latest-head">
                  <span class="ut-latest-emoji" aria-hidden="true">{evidence_emoji(row)}</span>
                  <span class="ut-latest-text">{latest_text(row)}</span>
                </div>
                <span class="ut-pbar" aria-hidden="true"><i class={progress_tone(row)} style={"width:#{progress_width(row.progress)}%"}></i></span>
                <div class="ut-latest-meta mono num">
                  <span>{progress_pct(row.progress)}</span>
                  <span>{runtime(row, @now)}</span>
                </div>
              </td>

              <td data-label="Command" class="ut-cmd-cell">
                <nav class="units-actions" aria-label={"Actions for #{identity_label(row.identity)}"}>
                  <.unit_control token={token} row={row} control={Map.get(@controls, token)} writable={@writable} />
                  <button
                    id={"units-inspect-#{token}"}
                    type="button"
                    class="units-action primary"
                    phx-click="inspect-unit"
                    phx-value-unit={token}
                    data-ticket-context-origin
                  >Inspect ticket</button>
                  <button
                    :if={conversation_handle(row)}
                    id={"units-conversation-#{token}"}
                    type="button"
                    class="units-action"
                    phx-click="read-conversation"
                    phx-value-unit={token}
                    aria-label={"Read conversation for #{identity_label(row.identity)}"}
                  >Read conversation</button>
                  <.link
                    patch={commands_path(row)}
                    class="units-action"
                    aria-label={"Open Commands for #{identity_label(row.identity)}"}
                  >Commands</.link>
                  <a
                    :if={github_url}
                    class="units-action"
                    href={github_url}
                    target="_blank"
                    rel="noopener noreferrer"
                  >GitHub <span aria-hidden="true">↗</span></a>
                  <button
                    :if={get_in(row, [:runtime, :bucket]) == :running}
                    type="button"
                    class="units-action"
                    phx-click="show-agent-log"
                    phx-value-unit={token}
                  >Agent log</button>
                </nav>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr(:token, :string, required: true)
  attr(:row, :map, required: true)
  attr(:control, :map, default: nil)
  attr(:writable, :boolean, default: false)

  defp unit_control(assigns) do
    affordance = UnitsControlPolicy.affordance(assigns.row, assigns.control)

    assigns =
      assigns
      |> assign(:affordance, affordance)
      |> assign(:identity_label, identity_label(assigns.row.identity))
      |> assign(:presentation, control_presentation(assigns.control))
      |> assign(:pause_note, pause_note(affordance, assigns.row))
      |> assign(:disabled?, control_button_disabled?(affordance, assigns.writable))

    ~H"""
    <div class="units-control" data-unit-control={@token}>
      <button
        :if={@affordance.state in [:enabled, :pending]}
        id={"units-control-#{@token}"}
        type="button"
        class={["units-action", "units-control-action", control_tone_class(@affordance)]}
        phx-click="request-unit-control"
        phx-value-unit={@token}
        phx-value-action={control_action(@affordance)}
        disabled={@disabled?}
        aria-disabled={to_string(@disabled?)}
        aria-label={control_aria_label(@affordance, @identity_label)}
      >{control_button_label(@affordance)}</button>

      <span
        :if={@affordance.state == :disabled}
        class="units-action unavailable units-control-disabled"
        aria-disabled="true"
        title={UnitsControlPolicy.disabled_reason(@affordance.reason)}
      >{control_disabled_label(@affordance.reason)}</span>

      <p :if={not @writable and @affordance.state != :disabled} class="units-control-note" role="note">
        Read-only — sign-in required to act
      </p>

      <p
        :if={@presentation}
        class={["units-control-status", "tone-#{@presentation.tone}"]}
        role="status"
        aria-live="polite"
        aria-atomic="true"
      >
        <span class="units-control-glyph" aria-hidden="true">{control_glyph(@presentation.tone)}</span>
        <span>{@presentation.announce}</span>
      </p>

      <p :if={present?(@pause_note)} class="units-control-owner">Paused: {@pause_note}</p>
    </div>
    """
  end

  defp control_presentation(nil), do: nil
  defp control_presentation(control) when is_map(control), do: UnitsControlPolicy.presentation(control)

  defp control_button_disabled?(%{state: :enabled}, true), do: false
  defp control_button_disabled?(_affordance, _writable), do: true

  defp control_action(%{action: action}) when action in [:pause, :resume], do: Atom.to_string(action)
  defp control_action(%{pending_action: action}) when action in [:pause, :resume], do: Atom.to_string(action)
  defp control_action(_affordance), do: nil

  defp control_button_label(%{state: :pending, pending_action: action}), do: "#{control_verb(action)}…"
  defp control_button_label(%{action: action}), do: control_verb(action)

  defp control_verb(:pause), do: "Pause"
  defp control_verb(:resume), do: "Resume"
  defp control_verb(_action), do: "Control"

  defp control_disabled_label(:no_identity), do: "Control unavailable"
  defp control_disabled_label(:remote_control), do: "Remote Control"
  defp control_disabled_label(:replaced_generation), do: "Superseded"
  defp control_disabled_label(_reason), do: "Control unavailable"

  defp control_aria_label(%{state: :pending, pending_action: action}, identity),
    do: "#{control_verb(action)} #{identity} — request pending"

  defp control_aria_label(%{action: action}, identity), do: "#{control_verb(action)} #{identity}"

  defp control_tone_class(%{state: :pending}), do: "is-pending"
  defp control_tone_class(%{action: :resume}), do: "is-resume"
  defp control_tone_class(_affordance), do: "is-pause"

  defp control_glyph(:pending), do: "◔"
  defp control_glyph(:applied), do: "✓"
  defp control_glyph(:error), do: "!"
  defp control_glyph(:warning), do: "△"
  defp control_glyph(_tone), do: "•"

  # Only surface the pause owner/reason when the row is actually paused (Resume
  # offered), so the "Paused: …" note never contradicts a live Pause control.
  defp pause_note(%{action: :resume}, %{reasons: %{pause: pause}}) when not is_nil(pause), do: label(pause)
  defp pause_note(_affordance, _row), do: nil

  attr(:progress, :map, required: true)

  defp progress(assigns) do
    assigns = assign(assigns, :percent, known_percent(assigns.progress))

    ~H"""
    <div
      :if={is_integer(@percent)}
      class="units-progress"
      role="progressbar"
      aria-label="Unit progress"
      aria-valuemin="0"
      aria-valuemax="100"
      aria-valuenow={@percent}
    >
      <span class="units-progress-track" aria-hidden="true"><span style={"width: #{@percent}%"}></span></span>
      <span class="mono num">{@percent}%</span>
    </div>
    <p :if={!is_integer(@percent)} class="units-progress unavailable">Progress unavailable</p>
    """
  end

  defp known_percent(%{status: :known, percent: percent}) when is_integer(percent) and percent in 0..100, do: percent
  defp known_percent(_progress), do: nil

  defp identity_label(%TrackerIdentity{owner: owner, repository: repository, identifier: identifier})
       when is_binary(owner) and is_binary(repository) and is_binary(identifier),
       do: "#{owner}/#{repository} ##{identifier}"

  defp identity_label(_identity), do: "Typed identity unavailable"

  defp conversation_handle(%{live_conversation: %{generation_handle: handle}}) when is_binary(handle), do: handle
  defp conversation_handle(_row), do: nil

  defp commands_path(%{identity: %TrackerIdentity{identifier: identifier}}) when is_binary(identifier),
    do: DecisionPath.inbox(:all, %{ticket: identifier})

  defp commands_path(_row), do: DecisionPath.inbox(:all)

  defp runtime(%{runtime: %{runtime_seconds: seconds}}, _now) when is_integer(seconds) and seconds >= 0,
    do: format_duration(seconds)

  defp runtime(%{timestamps: %{started_at: started_at}}, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, datetime, _offset} -> format_duration(max(DateTime.diff(now, datetime, :second), 0))
      _error -> "Unavailable"
    end
  end

  defp runtime(_row, _now), do: "Unavailable"

  defp format_duration(seconds) do
    hours = div(seconds, 3_600)
    minutes = div(rem(seconds, 3_600), 60)
    if hours > 0, do: "#{hours}h #{minutes}m", else: "#{minutes}m"
  end

  defp latest_evidence(%{status: :known, source: source}), do: evidence_source(source)
  defp latest_evidence(_evidence), do: nil

  defp evidence_source(%{kind: kind, name: name}) when not is_nil(kind) and is_binary(name),
    do: "#{label(kind)} · #{name}"

  defp evidence_source(source) when is_atom(source) or is_binary(source), do: label(source)
  defp evidence_source(_source), do: "Unavailable"

  defp progress_source(%{status: :known, source: source}) when not is_nil(source), do: label(source)
  defp progress_source(_progress), do: nil

  defp progress_freshness(%{freshness: freshness}) when not is_nil(freshness), do: freshness_label(freshness)
  defp progress_freshness(_progress), do: nil

  defp freshness_label(%{status: status}), do: label(status)
  defp freshness_label(value), do: label(value)

  defp provider_health(%{provider_health: health}) when is_map(health) do
    degraded =
      health
      |> Enum.filter(fn {_source, status} -> status not in [:available, :healthy] end)
      |> Enum.map_join(", ", fn {source, status} -> "#{label(source)} #{label(status)}" end)

    if degraded == "", do: "Available", else: degraded
  end

  defp provider_health(_row), do: "Unknown"

  defp command_count(count) when is_integer(count) and count > 0, do: "#{count} open"
  defp command_count(0), do: "None open"
  defp command_count(_count), do: "Unknown"

  @reason_labels [waiting: "Waiting", blocking: "Blocking", alert: "Alert", pause: "Paused", stuck: "Stuck"]

  # Only surface reasons that carry a real value, so healthy rows no longer repeat
  # "None reported" across every waiting/blocking/alert/pause/stuck row.
  defp present_reasons(reasons) when is_map(reasons) do
    Enum.flat_map(@reason_labels, fn {key, dt} ->
      case Map.get(reasons, key) do
        nil -> []
        value -> [{dt, label(value)}]
      end
    end)
  end

  defp present_reasons(_reasons), do: []

  defp complexity(value) when is_integer(value) and value > 0, do: Integer.to_string(value)
  defp complexity(_value), do: "Unknown"

  defp row_tone(%{reasons: %{blocking: blocking}}) when not is_nil(blocking), do: "is-blocked"
  defp row_tone(%{reasons: %{alert: alert}}) when not is_nil(alert), do: "has-alert"
  defp row_tone(_row), do: nil

  defp state_glyph(%{terminal?: true}), do: "✓"
  defp state_glyph(%{reasons: %{blocking: blocking}}) when not is_nil(blocking), do: "!"
  defp state_glyph(%{runtime: %{work_state: state}}) when state in [:working, :allocated], do: "●"
  defp state_glyph(%{runtime: %{work_state: state}}) when state in [:paused, :sleeping], do: "Ⅱ"
  defp state_glyph(_row), do: "○"

  defp display_rows(view) do
    view
    |> Map.get(:rows, [])
    |> Enum.map(fn row -> {row, UnitsPresenter.row_token(row), trusted_url(row)} end)
  end

  defp trusted_url(%{url: url, identity: %TrackerIdentity{} = identity}) do
    case Bounded.github_issue_url_for(url, identity) do
      {:ok, trusted_url} -> trusted_url
      :error -> nil
    end
  end

  defp trusted_url(_row), do: nil
  # --- compact-row helpers ---------------------------------------------------

  defp id_number(%TrackerIdentity{identifier: identifier}) when is_binary(identifier) and identifier != "", do: identifier
  defp id_number(_identity), do: "—"

  defp agent_label(family) when is_atom(family) and not is_nil(family),
    do: family |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp agent_label(_family), do: "Agent"

  defp agent_class(:claude), do: "is-claude"
  defp agent_class(:codex), do: "is-codex"
  defp agent_class(_family), do: "is-generic"

  defp model_label(%{resolved_model: model}) when is_binary(model) and model != "", do: model
  defp model_label(%{requested_model: model}) when is_binary(model) and model != "", do: model
  defp model_label(_row), do: nil

  defp priority_label(row), do: elem(priority(row), 0)
  defp priority_class(row), do: elem(priority(row), 1)

  defp priority(%{effort: :deep}), do: {"HIGH", "is-high"}
  defp priority(%{complexity: complexity}) when is_integer(complexity) and complexity >= 4, do: {"HIGH", "is-high"}
  defp priority(%{complexity: 3}), do: {"MED", "is-med"}
  defp priority(%{effort: :standard}), do: {"MED", "is-med"}
  defp priority(_row), do: {"LOW", "is-low"}

  defp lane_class(lane) when is_binary(lane) and lane != "", do: "is-lane-#{lane}"
  defp lane_class(_lane), do: nil

  defp evidence_emoji(%{latest_evidence: %{status: :known, source: %{kind: kind}}}), do: evidence_kind_emoji(kind)
  defp evidence_emoji(_row), do: "•"

  defp evidence_kind_emoji(:commit), do: "🔨"
  defp evidence_kind_emoji(:pull_request), do: "🔀"
  defp evidence_kind_emoji(:branch), do: "🌿"
  defp evidence_kind_emoji(:log), do: "📋"
  defp evidence_kind_emoji(:queue), do: "⏳"
  defp evidence_kind_emoji(_kind), do: "•"

  defp latest_text(%{latest_evidence: %{status: :known, source: %{name: name}}}) when is_binary(name) and name != "", do: name
  defp latest_text(_row), do: "No recent activity"

  defp progress_width(progress), do: known_percent(progress) || 0

  defp progress_pct(progress) do
    case known_percent(progress) do
      nil -> "—"
      percent -> "#{percent}%"
    end
  end

  defp progress_tone(%{reasons: %{blocking: blocking}}) when not is_nil(blocking), do: "is-blocked"
  defp progress_tone(%{reasons: %{alert: alert}}) when not is_nil(alert), do: "has-alert"
  defp progress_tone(_row), do: nil

  defp present?(value), do: not is_nil(value) and value != ""
  defp known(value, fallback \\ "Unknown")
  defp known(value, _fallback) when is_binary(value) and value != "", do: value
  defp known(_value, fallback), do: fallback
  defp known_label(value) when not is_nil(value) and value != "", do: label(value)
  defp known_label(_value), do: "Unknown"
  defp label(nil), do: "Unknown"

  defp label(value),
    do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
