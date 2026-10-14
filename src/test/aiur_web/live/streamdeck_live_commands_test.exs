defmodule AiurWeb.StreamdeckLiveCommandsTest do
  use AiurWeb.StreamdeckLiveCase

  test "key presses request pause for running and resume for paused agents" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    html = render_hook(view, "key-press", %{"identifier" => "1352"})
    assert html =~ "Pause requested for #1352"
    assert %{sd_mode: :cmd, sd_active: %{identifier: "1352"}} = streamdeck_assigns(view)
    assert_receive {:streamdeck_pause, "1352"}, 1000

    render_hook(view, "dial-press", %{"index" => "0", "action" => "back"})
    html = render_hook(view, "key-press", %{"identifier" => "1345"})

    assert html =~ "Resume requested for #1345"
    assert %{sd_mode: :cmd, sd_active: %{identifier: "1345"}} = streamdeck_assigns(view)
    assert_receive {:streamdeck_resume, "1345"}, 1000
  end

  test "the pause command key controls the agent and adopts the state the orchestrator settles on" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    html = render_hook(view, "key-press", %{"identifier" => "1352"})
    assert_receive {:streamdeck_pause, "1352"}, 1000

    # The key-press pause already settled the snapshot, but the view has not
    # re-read it yet, so the key still reads Pause.
    assert command_key(html, "pause") =~ "Pause"
    assert command_key(html, "pause") =~ ~s(data-command-state="running")

    # The fleet topic is what re-reads the settled state; a command press does
    # not block on a snapshot read.
    send(view.pid, {:status_changed, %{identifier: "1352"}})
    html = render(view)

    # The key adopts the state the orchestrator settled on, not the one the
    # press assumed: it now offers Play, with the paused state and icon.
    assert command_key(html, "pause") =~ "Play"
    assert command_key(html, "pause") =~ ~s(data-command-state="paused")
    assert command_icon(html, "pause") == "play"

    # Pressing the same key again resolves to resume server-side, because the
    # direction is read from orchestrator state rather than from the client.
    html = render_hook(view, "command-press", %{"command" => "pause"})

    assert_receive {:streamdeck_resume, "1352"}, 1000
    assert html =~ "Resume requested for #1352"

    send(view.pid, {:status_changed, %{identifier: "1352"}})
    html = render(view)

    assert command_key(html, "pause") =~ "Pause"
    assert command_key(html, "pause") =~ ~s(data-command-state="running")
    assert command_icon(html, "pause") == "pause"
  end

  # The agent view has four slots and the mic took the fourth, so the priority
  # key went. Priority itself did not: the grid still stars a prioritized agent
  # and still sorts on it, which is what this now guards — the key is gone, the
  # state it used to toggle is not.
  test "the agent view offers no priority key while the grid still stars a prioritized agent" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    # 1352 is the prioritized running agent in the fixture, so its grid key
    # wears the star before anything is pressed.
    assert has_element?(view, ~s(.sd-agent-key[data-streamdeck-identifier="1352"] .sd-ag-prio))

    html = render_hook(view, "key-press", %{"identifier" => "1352"})
    assert_receive {:streamdeck_pause, "1352"}, 1000

    refute html =~ ~s(data-streamdeck-command="priority")
    refute has_element?(view, ~s(button[data-streamdeck-command="priority"]))

    # A forged press for the retired command reaches the catch-all clause and
    # changes nothing, rather than finding a control path that still exists.
    html = render_hook(view, "command-press", %{"command" => "priority"})
    refute html =~ "Prioritize requested"
    refute html =~ "Deprioritize requested"

    render_hook(view, "dial-press", %{"index" => "0", "action" => "back"})
    assert has_element?(view, ~s(.sd-agent-key[data-streamdeck-identifier="1352"] .sd-ag-prio))
  end

  test "the settings key opens a pane that admits microphone choice lives on the sidecar host" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    render_hook(view, "key-press", %{"identifier" => "1352"})
    assert_receive {:streamdeck_pause, "1352"}, 1000

    html = render_hook(view, "command-press", %{"command" => "settings"})

    assert html =~ ~s(data-mode-view="settings")
    # Microphone enumeration happens on the machine running the sidecar, so the
    # pane says so and offers nothing to pick. A device list invented in the
    # browser could not be true.
    assert html =~ "machine running the sidecar"
    refute html =~ ~s(<select)

    # Back returns to the command keys rather than falling through to the grid.
    html = render_hook(view, "dial-press", %{"index" => "0", "action" => "back"})
    assert html =~ ~s(data-mode-view="cmd")
  end

  test "read-only mode renders the command keys disabled and refuses the control call" do
    endpoint_config = Application.get_env(:aiur, Endpoint)
    Endpoint.config_change(%{Endpoint => Keyword.put(endpoint_config, :dashboard_writable, false)}, [])

    try do
      {:ok, view, _html} = live(build_conn(), "/streamdeck")
      html = render_hook(view, "key-press", %{"identifier" => "1352"})

      assert html =~ "sd-cmd-key is-disabled"

      # Element selectors rather than substring checks: a bare `html =~ "disabled"`
      # also matches the `is-disabled` class, so it would pass on a button that is
      # still clickable. The hook skips `disabled` keys, so a disabled attribute
      # is what actually stops the press from ever being emitted.
      for command <- ~w(pause mic) do
        assert has_element?(view, ~s(button[data-streamdeck-command="#{command}"][disabled][aria-disabled="true"]))
      end

      # Logs and Settings are navigation rather than fleet control, so they stay
      # available. They are the negative control: they prove the disabling above
      # is the read-only gate and not simply every key being rendered inert.
      for command <- ~w(logs settings) do
        assert has_element?(view, ~s(button[data-streamdeck-command="#{command}"][aria-disabled="false"]))
        refute has_element?(view, ~s(button[data-streamdeck-command="#{command}"][disabled]))
      end

      # A forged press that bypasses the client gate is still refused server-side.
      html = render_hook(view, "command-press", %{"command" => "pause"})

      assert html =~ "Read-only dashboard: controls are disabled"
      refute_receive {:streamdeck_pause, "1352"}, 100
    after
      Endpoint.config_change(%{Endpoint => endpoint_config}, [])
    end
  end

  test "a failed command control call surfaces in the status region instead of being swallowed" do
    endpoint_config = Application.get_env(:aiur, Endpoint)

    failing_config =
      Keyword.merge(endpoint_config,
        agent_chat_pause_fun: fn _identifier -> {:error, :tracker_unavailable} end,
        agent_chat_resume_fun: fn _identifier -> raise "tracker exploded" end
      )

    Endpoint.config_change(%{Endpoint => failing_config}, [])

    try do
      {:ok, view, _html} = live(build_conn(), "/streamdeck")
      render_hook(view, "key-press", %{"identifier" => "1352"})

      html = render_hook(view, "command-press", %{"command" => "pause"})

      assert html =~ "Pause failed: :tracker_unavailable"
      # The failed call must not flip the key: the agent is still running.
      assert command_key(html, "pause") =~ "Pause"
      assert command_key(html, "pause") =~ ~s(data-command-state="running")

      # The status banner (outside the device) carries the failure visibly, so
      # the operator sees a swallowed control call rather than nothing.
      assert html =~ ~s(id="sd-control-status" class="streamdeck-status")

      # A raise inside the control call is caught rather than taking the view
      # down with it. 1345 is paused, so the same key resolves to resume.
      render_hook(view, "key-press", %{"identifier" => "1345"})
      html = render_hook(view, "command-press", %{"command" => "pause"})

      assert html =~ "Resume failed:"
      assert html =~ "tracker exploded"
      assert command_key(html, "pause") =~ "Play"
    after
      Endpoint.config_change(%{Endpoint => endpoint_config}, [])
    end
  end

  test "cmd mode offers the design's five command keys, with Mic as press-and-hold" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    html = render_hook(view, "key-press", %{"identifier" => "1352"})
    assert_receive {:streamdeck_pause, "1352"}, 1000

    # Five keys, in the design's order, with the design's labels and sub lines.
    # Prioritize is not among them: the slot it held is Settings now.
    assert [
             {"pause", "Pause", "HOLD"},
             {"logs", "Logs", "SCROLL"},
             {"mic", "Mic", "HOLD"},
             {"settings", "Settings", "OPEN"},
             {"commands", "Commands", "OPEN"}
           ] == rendered_command_keys(html)

    # Mic is the only press-and-hold key, so it is the only one the hook drives
    # from pointer events rather than a click.
    assert has_element?(view, ~s(button[data-streamdeck-command="mic"][data-command-hold="true"]))

    for command <- ~w(pause logs settings) do
      refute has_element?(view, ~s(button[data-streamdeck-command="#{command}"][data-command-hold]))
    end

    # A click-shaped command-press for mic is inert server-side, so the
    # press-and-hold contract cannot be worked around from the client: "mic"
    # is not a control command and reaches the catch-all clause.
    html = render_hook(view, "command-press", %{"command" => "mic"})
    assert command_key(html, "mic") =~ ~s(data-command-state="idle")
    refute_receive {:streamdeck_pause, "1352"}, 100
  end

  test "holding the mic key marks it live and releasing clears it" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    render_hook(view, "key-press", %{"identifier" => "1352"})
    assert_receive {:streamdeck_pause, "1352"}, 1000

    html = render_hook(view, "mic-hold", %{"active" => true})
    assert command_key(html, "mic") =~ ~s(data-command-state="live")
    assert html =~ "sd-mic-key mic-live"

    # Release must clear it. A hold that latched would leave the mic open after
    # the operator let go, which is the failure press-and-hold exists to avoid.
    html = render_hook(view, "mic-hold", %{"active" => false})
    assert command_key(html, "mic") =~ ~s(data-command-state="idle")
    refute html =~ "sd-mic-key mic-live"
  end

  test "read-only mode disables the mic key and refuses the hold" do
    endpoint_config = Application.get_env(:aiur, Endpoint)
    Endpoint.config_change(%{Endpoint => Keyword.put(endpoint_config, :dashboard_writable, false)}, [])

    try do
      {:ok, view, _html} = live(build_conn(), "/streamdeck")
      render_hook(view, "key-press", %{"identifier" => "1352"})

      assert has_element?(view, ~s(button[data-streamdeck-command="mic"][disabled][aria-disabled="true"]))

      html = render_hook(view, "mic-hold", %{"active" => true})

      assert html =~ "Read-only dashboard: controls are disabled"
      assert command_key(html, "mic") =~ ~s(data-command-state="idle")
      refute html =~ "sd-mic-key mic-live"
    after
      Endpoint.config_change(%{Endpoint => endpoint_config}, [])
    end
  end

  test "renders state-derived command keys with three disabled blank slots" do
    {:ok, view, html} = live(build_conn(), "/streamdeck")

    refute html =~ "data-streamdeck-command"
    html = render_hook(view, "key-press", %{"identifier" => "1352"})

    assert command_key(html, "pause") =~ "Pause"
    assert command_key(html, "settings") =~ "Settings"
    assert length(Regex.scan(~r/data-streamdeck-command=/, html)) == 5
    assert length(Regex.scan(~r/<button[^>]*disabled[^>]*aria-hidden="true"[^>]*>/, html)) == 3

    html = render_hook(view, "key-press", %{"identifier" => "1345"})

    assert command_key(html, "pause") =~ "Play"
  end

  test "command key icons track pause state alongside their labels" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    html = render_hook(view, "key-press", %{"identifier" => "1352"})

    assert command_icon(html, "pause") == "pause"
    assert command_icon(html, "logs") == "logs"
    assert command_icon(html, "mic") == "mic"
    assert command_icon(html, "settings") == "settings"

    html = render_hook(view, "key-press", %{"identifier" => "1345"})

    assert command_icon(html, "pause") == "play"
  end

  test "the Commands key is always on the agent row and opens the history view" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    html = render_hook(view, "key-press", %{"identifier" => "1352"})
    assert_receive {:streamdeck_pause, "1352"}, 1000

    # The Commands key is a stable destination, not a conditional alert: it is
    # present whether or not the agent has an open Command.
    assert command_key(html, "commands") =~ "Commands"
    assert command_key(html, "commands") =~ ~s(data-command-state="ready")

    html = render_hook(view, "command-press", %{"command" => "commands"})

    assert html =~ ~s(id="sd-commands-view")
    assert html =~ ~s(data-mode-view="commands")
    # History-first: the answerable Command carries an OPEN badge, newest first.
    assert html =~ "Ship the change?"
    assert html =~ ~s(data-command-key="dec-open-1")
    assert html =~ "Rotate the key?"
    assert html =~ "OPEN"
  end

  test "selecting a history key enters the detail view where an option reads but never commits" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    render_hook(view, "key-press", %{"identifier" => "1352"})
    assert_receive {:streamdeck_pause, "1352"}, 1000
    render_hook(view, "command-press", %{"command" => "commands"})

    html = render_hook(view, "command-select", %{"index" => 0})

    # The detail view paints the Command's options and the strip reads the
    # Command's own description before anything is selected.
    assert html =~ ~s(data-commands-view="detail")
    assert html =~ ~s(data-command-option="0")
    assert html =~ "Ship it"
    assert html =~ "The checks are green."

    html = render_hook(view, "command-select", %{"index" => 0})

    # Selecting an option is reading, not committing: the strip now reads that
    # option's detail and no answer is recorded (the browser cannot approve).
    assert html =~ ~s(data-command-selected="true")
    assert html =~ "Merge and deploy now."
  end

  test "back returns from the Commands page to the agent row" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    render_hook(view, "key-press", %{"identifier" => "1352"})
    assert_receive {:streamdeck_pause, "1352"}, 1000
    render_hook(view, "command-press", %{"command" => "commands"})
    render_hook(view, "command-select", %{"index" => 0})

    html = render_hook(view, "dial-press", %{"action" => "back"})
    assert html =~ ~s(data-mode="cmd")
    refute html =~ ~s(id="sd-commands-view")
  end

  test "a Command with no description reads as No description" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    render_hook(view, "key-press", %{"identifier" => "1352"})
    assert_receive {:streamdeck_pause, "1352"}, 1000
    render_hook(view, "command-press", %{"command" => "commands"})
    # dec-done-1 has no context and no options: entering it reads No description.
    html = render_hook(view, "command-select", %{"index" => 1})
    assert html =~ "No description"
  end

  test "an unavailable Commands store says so instead of an empty history" do
    endpoint_config = Application.get_env(:aiur, Endpoint)

    Endpoint.config_change(
      %{Endpoint => Keyword.put(endpoint_config, :streamdeck_commands_fun, fn _, _ -> {:ok, %{"items" => [], "unavailable" => true}} end)},
      []
    )

    try do
      {:ok, view, _html} = live(build_conn(), "/streamdeck")
      render_hook(view, "key-press", %{"identifier" => "1352"})
      assert_receive {:streamdeck_pause, "1352"}, 1000
      html = render_hook(view, "command-press", %{"command" => "commands"})
      assert html =~ "UNAVAILABLE"
    after
      Endpoint.config_change(%{Endpoint => endpoint_config}, [])
    end
  end
end
