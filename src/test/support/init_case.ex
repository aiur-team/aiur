defmodule Aiur.InitCase do
  @moduledoc false
  # Shared scripted-io and dependency fixtures for the `aiur init` wizard tests.
  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias Aiur.Init
  alias Aiur.Workflow

  using do
    quote do
      use ExUnit.Case, async: true

      import Aiur.InitCase

      alias Aiur.CodingAgent
      alias Aiur.CodingAgent.Providers.Fake
      alias Aiur.GitHub.Labels
      alias Aiur.Init
      alias Aiur.Workflow
    end
  end

  @location_label "Where will you store aiur settings for this project?"

  # Every topic the shipped alert examples must keep populated. Kept in sync with
  # the real event names so the scaffolded map fires sounds with zero editing.
  @alert_topics [
    "ticket.*.issue.label.added.agent.todo",
    "ticket.*.issue.label.added.agent.in-progress",
    "ticket.*.issue.label.added.agent.human-review",
    "ticket.*.issue.label.added.agent.rework",
    "ticket.*.pr.merged",
    "ticket.*.issue.state.changed",
    "system.dispatch.todo_capacity_exceeded",
    "system.github_app_token.refresh_failed",
    "system.github_app_token.permission_violation",
    "system.github_app_token.identity_mismatch",
    "system.github_app_token.refresh_recovered",
    "system.dispatch.prewarm_blocked",
    "system.dispatch.prewarm_blocked.resolved",
    "system.dispatch.capacity_starved",
    "system.dispatch.capacity_starved.resolved",
    "system.fleet.capacity.starved",
    "system.fleet.capacity.starved.resolved",
    "system.tracker.auth_preflight_failed",
    "system.tracker.auth_preflight_failed.resolved",
    "ticket.*.agent.error.tokens_exhausted",
    "ticket.*.agent.retry_exhausted",
    "ticket.*.agent.review_feedback_delivery_deferred",
    "ticket.*.agent.paused",
    "ticket.*.agent.paused.resolved",
    "ticket.*.agent.attention.*",
    "ticket.*.agent.attention.*.resolved",
    "ticket.*.agent.unpaused",
    "ticket.*.chat.opened",
    "ticket.*.chat.closed",
    "ticket.*.agent.phase.brainstorm.start",
    "ticket.*.agent.phase.brainstorm.end",
    "ticket.*.agent.phase.plan.start",
    "ticket.*.agent.phase.plan.end",
    "ticket.*.agent.phase.work.start",
    "ticket.*.agent.phase.work.end",
    "ticket.*.agent.phase.review.start",
    "ticket.*.agent.phase.review.end"
  ]

  @example_file Path.expand("../../../.aiur/examples/config.example", __DIR__)

  setup do
    dir = Aiur.TestSupport.tmp_root!("aiur-init-test")
    target = Path.join([dir, ".aiur", "config"])
    File.mkdir_p!(Path.dirname(target))
    # The wizard writes `prompt_file: prompt.md`; Workflow.load resolves it, so
    # the file must exist alongside the config for the written config to load.
    File.write!(Path.join([dir, ".aiur", "prompt.md"]), "# agent prompt\n")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, target: target}
  end

  # Label-keyed scripted io: each prompt looks up its answer by label and
  # falls back to the supplied default, so a test scripts only the answers it
  # cares about regardless of prompt order.
  def io(parent, answers \\ %{}) do
    %{
      puts: fn message ->
        message = IO.chardata_to_string(message)
        send(parent, {:io_trace, {:puts, message}})
        send(parent, {:puts, message})
        :ok
      end,
      input: fn label, default, _hint ->
        send(parent, {:io_trace, {:input, label}})
        send(parent, {:input_label, label})
        Map.get(Map.get(answers, :input, %{}), label, default)
      end,
      select: fn label, opts, default ->
        send(parent, {:io_trace, {:select, label}})
        send(parent, {:select_prompt, label, opts, default})
        Map.get(Map.get(answers, :select, %{}), label, default)
      end,
      multiselect: fn label, _opts, defaults ->
        Map.get(Map.get(answers, :multiselect, %{}), label, defaults)
      end,
      confirm: fn label, default ->
        send(parent, {:io_trace, {:confirm, label}})
        send(parent, {:confirm, label})
        Map.get(Map.get(answers, :confirm, %{}), label, default)
      end
    }
  end

  def deps(parent, dir, target, overrides \\ %{}) do
    Map.merge(
      %{
        config_target: fn _location -> target end,
        legacy_config_target: fn _location -> Path.join(dir, ".aiurconfig") end,
        existing_config_path: &existing_path/1,
        load_config: fn t ->
          with {:ok, loaded} <- Workflow.load(t), do: {:ok, loaded.config}
        end,
        read_example: fn -> File.read!(@example_file) end,
        detect_repo: fn -> nil end,
        detect_default_branch: fn _repo -> "main" end,
        setup_repo_state: fn tracker ->
          send(parent, {:repo_state, tracker})
          :ok
        end,
        detect_toolchain: fn -> :none end,
        prewarm_build: fn url, cmd ->
          send(parent, {:prewarm_build, url, cmd})
          {:ok, "/base"}
        end,
        global_alerts_path: fn -> Path.join([dir, "home", ".aiur", "alerts"]) end,
        existing_alerts_path: &existing_path/1,
        write_config: fn t, yaml ->
          File.mkdir_p!(Path.dirname(t))
          File.write!(t, yaml)
          send(parent, {:write, t})
          {:ok, t}
        end,
        append_config: fn t, block ->
          existing = File.read!(t)
          File.write!(t, String.trim_trailing(existing, "\n") <> "\n\n" <> IO.iodata_to_binary(block))
          send(parent, {:append, t})
          {:ok, t}
        end,
        ensure_prompt_file: fn t, pf, _repo ->
          path = Path.expand(pf, Path.dirname(t))

          if File.regular?(path) do
            {:exists, path}
          else
            File.write!(path, "# prompt\n")
            {:created, path}
          end
        end,
        ensure_aiurhooks: fn t ->
          path = Path.join(Path.dirname(t), "hooks")

          if File.regular?(path) do
            {:exists, path}
          else
            File.write!(path, "after_create: echo created\n")
            {:created, path}
          end
        end,
        ensure_alerts: &ensure_alerts_for_test/2,
        ensure_prewarm_file: fn t, cmd ->
          path = Path.join(Path.dirname(t), "prewarm")
          File.write!(path, cmd <> "\n")
          send(parent, {:prewarm_file, cmd})
          {:created, path}
        end,
        add_gitignore_entry: fn entry ->
          path = Path.join(dir, ".gitignore")
          existing = if File.regular?(path), do: File.read!(path), else: ""

          if existing |> String.split("\n") |> Enum.member?(entry) do
            {:exists, path}
          else
            File.write!(path, existing <> entry <> "\n")
            send(parent, {:gitignore, entry})
            {:added, path}
          end
        end,
        ensure_env: fn content ->
          env_path = Path.join(dir, ".env")

          if File.regular?(env_path) do
            {:exists, env_path}
          else
            File.write!(env_path, content)
            {:created, env_path}
          end
        end,
        check_agent_auth: fn _kind -> :ok end,
        check_codex_sandbox: fn -> :ok end,
        install_claude_app_server: fn -> :ok end,
        claude_version: fn -> {:ok, "1.1.0"} end,
        # No installed CLI to ask in the wizard tests; discovery degrading to an
        # error is the offline path, and init must finish through it.
        discover_models: fn _backend -> {:error, :offline} end,
        repo_root: fn -> dir end,
        github_login: fn -> "octocat" end,
        github_bot_account_default: fn -> nil end,
        github_token: fn -> nil end,
        check_ci_readiness: fn _tracker -> {:ok, %{ready?: true, base_branch: "main", required_checks: ["ci / required"]}} end,
        list_labels: fn _tracker -> {:ok, []} end,
        create_labels: fn tracker, labels ->
          send(parent, {:labels, tracker, labels})
          :ok
        end
      },
      overrides
    )
  end

  def existing_path(path) do
    if File.regular?(path), do: path
  end

  def ensure_alerts_for_test(target, source_path) do
    path = Path.join(Path.dirname(target), "alerts")

    if File.regular?(path) do
      {:exists, path}
    else
      write_alerts_for_test(path, source_path)
      {:created, path}
    end
  end

  def write_alerts_for_test(path, source_path) when is_binary(source_path) do
    File.cp!(source_path, path)
  end

  def write_alerts_for_test(path, _source_path) do
    File.write!(path, "alerts: {}\n")
  end

  def written_config(path) do
    assert {:ok, loaded} = Workflow.load(path)
    loaded.config
  end

  def assert_filled_alert_template(template, sound_path_regex) do
    assert {:ok, %{"alerts" => alerts}} = YamlElixir.read_from_string(template)
    assert alerts |> Map.keys() |> Enum.sort() == Enum.sort(@alert_topics)

    for topic <- @alert_topics do
      assert %{"message" => message, "sound" => sounds} = Map.fetch!(alerts, topic)
      assert is_binary(message) and message != ""
      assert is_list(sounds) and sounds != []
      assert Enum.all?(sounds, &Regex.match?(sound_path_regex, &1))
    end
  end

  def puts_log(acc \\ []) do
    receive do
      {:puts, msg} -> puts_log([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def io_trace(acc \\ []) do
    receive do
      {:io_trace, event} -> io_trace([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Resume init against an enabled-prewarm config whose first warm-base build
  # fails with `reason`, returning the joined operator-facing output.
  def run_prewarm_failure(parent, dir, target, reason) do
    File.write!(target, """
    tracker:
      kind: github
      base_branch: main
      github:
        repo: octo/repo
    agent:
      kind: claude
    prewarm:
      enabled: true
      base_build: mise exec -- npm ci && mise exec -- npm run build
    """)

    d = deps(parent, dir, target, %{prewarm_build: fn _url, _cmd -> {:error, reason} end})
    assert :ok = Init.run(%{force: false}, io(parent), d)
    Enum.join(puts_log(), "\n")
  end

  def input_labels(acc \\ []) do
    receive do
      {:input_label, label} -> input_labels([label | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def auth_kinds(acc \\ []) do
    receive do
      {:auth_kind, kind} -> auth_kinds([kind | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def input_hints(acc \\ []) do
    receive do
      {:input_hint, label, hint} -> input_hints([{label, hint} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def select_labels(acc \\ []) do
    receive do
      {:select_label, label} -> select_labels([label | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def select_prompts(acc \\ []) do
    receive do
      {:select_prompt, label, options, default} ->
        select_prompts([{label, options, default} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Flattened labels across every staged create_labels call.
  def labels_created(acc \\ []) do
    receive do
      {:labels, _tracker, labels} -> labels_created(acc ++ labels)
    after
      0 -> acc
    end
  end

  def codeowners_path(dir), do: Path.join([dir, ".github", "CODEOWNERS"])

  # Prompts the wizard asked the operator to confirm (one per stage that has
  # labels to create).
  def confirm_prompts(acc \\ []) do
    receive do
      {:confirm, label} -> confirm_prompts([label | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def github_answers(overrides \\ %{}) do
    base = %{
      select: %{@location_label => "repo", "Issue tracker" => "github"},
      input: %{"GitHub repo (owner/name)" => "octo/repo"},
      multiselect: %{"Which agents to support" => ["claude"]}
    }

    Map.merge(base, overrides, fn _k, v1, v2 -> Map.merge(v1, v2) end)
  end
end
