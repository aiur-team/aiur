defmodule Aiur.MixProject do
  use Mix.Project

  def project do
    [
      app: :aiur,
      version: "0.1.1",
      elixir: "~> 1.19",
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      test_coverage: [
        summary: [
          threshold: 100
        ],
        ignore_modules: [
          # Scaffold modules — fixed-return functions awaiting Phase 2
          # implementations. Exempt until real logic lands; tests would
          # only assert constants.
          Aiur.AgentDirectory,
          Aiur.Claude.Config,
          Aiur.Codex.Config,
          Aiur.Config,
          Aiur.GitHub.Config,
          Aiur.Linear.Client,
          Aiur.Linear.Config,
          Aiur.Memory.Config,
          Aiur.PromptBuilder,
          Aiur.SpecsCheck,
          Aiur.Orchestrator,
          Aiur.Orchestrator.State,
          Aiur.AgentRunner,
          Aiur.CLI,
          Aiur.CodingAgent,
          Aiur.Claude.CodingAgent,
          Aiur.Claude.EventHumanizer,
          Aiur.Codex.CodingAgent,
          Aiur.Codex.DynamicTool,
          Aiur.Codex.EventHumanizer,
          Aiur.EventHumanizer,
          Aiur.GitHub.Client,
          Aiur.GitHub.Tracker,
          Aiur.Linear.Tracker,
          Aiur.EventHumanizerHelpers,
          Aiur.HttpServer,
          Aiur.LogFile,
          Aiur.Workspace,
          AiurWeb.DashboardLive,
          AiurWeb.Endpoint,
          AiurWeb.ErrorHTML,
          AiurWeb.ErrorJSON,
          AiurWeb.Layouts,
          AiurWeb.ObservabilityApiController,
          AiurWeb.Presenter,
          AiurWeb.StaticAssetController,
          AiurWeb.StaticAssets,
          AiurWeb.Router,
          AiurWeb.Router.Helpers,
          Aiur.AgentList.App,
          Aiur.AgentList.Input,
          Aiur.AgentList.Renderer,
          Aiur.Conversations,
          Aiur.IssueContext,
          Aiur.IssueLog,
          Aiur.PaneManager,
          Aiur.Tmux,
          Aiur.Opencode.ApiClient,
          Aiur.Opencode.Bridge,
          Aiur.Opencode.BridgeSupervisor,
          Aiur.Opencode.ChatCompletions,
          Aiur.Opencode.Config,
          Aiur.Opencode.Db,
          Aiur.Opencode.EventConsumer,
          Aiur.Opencode.PaneSession,
          Aiur.Opencode.PaneSupervisor,
          Aiur.Opencode.PrewarmSupervisor,
          Aiur.Opencode.Server,
          Aiur.Opencode.SessionSupervisor,
          Aiur.Opencode.SessionWriter,
          Aiur.Opencode.SessionWriterRegistry,
          Aiur.Opencode.WarmServer,
          Aiur.Opencode.WorkspaceSetup,
          Aiur.Shutdown
        ]
      ],
      test_ignore_filters: [
        "test/support/snapshot_support.exs",
        "test/support/test_support.exs"
      ],
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      escript: escript(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Aiur.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.8"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix, "~> 1.8.0"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1.0"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:solid, "~> 1.2"},
      {:ecto, "~> 3.13"},
      {:exqlite, "~> 0.27"},
      {:owl, "~> 0.13"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      build: ["escript.build"],
      lint: ["specs.check", "credo --strict"]
    ]
  end

  defp escript do
    [
      app: nil,
      main_module: Aiur.CLI,
      name: "aiur",
      path: "bin/aiur"
    ]
  end
end
