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
              <th>Unit</th>
              <th>State</th>
              <th>Progress and evidence</th>
              <th>Execution</th>
              <th>Waiting and Commands</th>
              <th><span class="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody id="units-rows">
            <tr
              :for={{row, token, github_url} <- @rows}
              id={"unit-#{token}"}
              class={["units-row", row_tone(row)]}
              data-unit-token={token}
            >
              <td data-label="Unit">
                <div class="units-identity">
                  <span class="units-state-glyph" aria-hidden="true">{state_glyph(row)}</span>
                  <div>
                    <strong>{known(row.title, "Title unknown")}</strong>
                    <span class="ticket-id">{identity_label(row.identity)}</span>
                    <span :if={present?(row.build_lane)} class="units-lane">Lane {row.build_lane}</span>
                  </div>
                </div>
              </td>

              <td data-label="State">
                <dl class="units-facts compact">
                  <div><dt>Lifecycle</dt><dd>{label(row.lifecycle)}</dd></div>
                  <div><dt>Tracker</dt><dd>{known_label(row.tracker_state)}</dd></div>
                  <div><dt>Runtime</dt><dd class="mono num">{runtime(row, @now)}</dd></div>
                  <div><dt>Health</dt><dd>{provider_health(row)}</dd></div>
                </dl>
              </td>

              <td data-label="Progress and evidence">
                <.progress progress={row.progress} />
                <dl class="units-facts compact">
                  <div><dt>Progress source</dt><dd>{progress_source(row.progress)}</dd></div>
                  <div><dt>Freshness</dt><dd>{progress_freshness(row.progress)}</dd></div>
                  <div><dt>Latest evidence</dt><dd>{latest_evidence(row.latest_evidence)}</dd></div>
                </dl>
              </td>

              <td data-label="Execution">
                <dl class="units-facts compact">
                  <div><dt>Backend</dt><dd>{known_label(row.backend)}</dd></div>
                  <div><dt>Agent</dt><dd>{known_label(row.agent_family)}</dd></div>
                  <div><dt>Requested model</dt><dd>{known(row.requested_model)}</dd></div>
                  <div><dt>Resolved model</dt><dd>{known(row.resolved_model)}</dd></div>
                  <div><dt>Effort</dt><dd>{known_label(row.effort)}</dd></div>
                  <div><dt>Complexity</dt><dd>{complexity(row.complexity)}</dd></div>
                  <div><dt>Lane</dt><dd>{known(row.build_lane)}</dd></div>
                </dl>
              </td>

              <td data-label="Waiting and Commands">
                <dl class="units-facts compact">
                  <div><dt>Waiting</dt><dd>{reason(row.reasons, :waiting)}</dd></div>
                  <div><dt>Blocking</dt><dd>{reason(row.reasons, :blocking)}</dd></div>
                  <div><dt>Alert</dt><dd>{reason(row.reasons, :alert)}</dd></div>
                  <div><dt>Paused</dt><dd>{reason(row.reasons, :pause)}</dd></div>
                  <div><dt>Stuck</dt><dd>{reason(row.reasons, :stuck)}</dd></div>
                  <div><dt>Open Commands</dt><dd>{command_count(row.open_command_count)}</dd></div>
                </dl>
              </td>

              <td data-label="Actions">
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
                  <span class="units-action unavailable" aria-disabled="true" title="Chat destination is not available yet">Chat unavailable</span>
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
      |> assign(:pause_note, pause_note(assigns.row))
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

  defp pause_note(%{reasons: %{pause: pause}}) when not is_nil(pause), do: label(pause)
  defp pause_note(_row), do: nil

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
  defp latest_evidence(_evidence), do: "Unavailable"

  defp evidence_source(%{kind: kind, name: name}) when not is_nil(kind) and is_binary(name),
    do: "#{label(kind)} · #{name}"

  defp evidence_source(source) when is_atom(source) or is_binary(source), do: label(source)
  defp evidence_source(_source), do: "Unavailable"

  defp progress_source(%{status: :known, source: source}) when not is_nil(source), do: label(source)
  defp progress_source(_progress), do: "Unavailable"

  defp progress_freshness(%{freshness: freshness}) when not is_nil(freshness), do: freshness_label(freshness)
  defp progress_freshness(_progress), do: "Unknown"

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

  defp reason(reasons, name) when is_map(reasons) do
    case Map.get(reasons, name) do
      nil -> "None reported"
      value -> label(value)
    end
  end

  defp reason(_reasons, _name), do: "Unknown"

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
