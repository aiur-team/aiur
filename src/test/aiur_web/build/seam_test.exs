defmodule AiurWeb.Build.SeamTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  # C3-T02 uses Endpoint (read through EndpointConfig) only for dashboard_writable; C3-T03 adds legacy Units decoding.
  # C8-T01 Now-band rows read the Units catalog through its policy, tracker identity, and pause-reason facades;
  # components.json declares these (dashboard-ui requires projections, kernel and orchestration).
  # MP-E8-C8-T04 reads C8-T01 Units through the existing shared payload cache.
  @allowed ~w(AiurWeb.OperatorControlCenter.PayloadLoader AiurWeb.BuildLive AiurWeb.Endpoint AiurWeb.EndpointConfig Aiur.BuildQueue Aiur.AgentChat AiurWeb.Layouts AiurWeb.FinancialDataAccess AiurWeb.Presenter AiurWeb.BuildOrder.Runtime AiurWeb.OperatorControlCenter.UnitsURL Aiur.Projections.UnitsPolicy Aiur.TrackerIdentity Aiur.Orchestrator.State)
  @usage_facades [
    # Authorized usage reads configured Claude account labels.
    "Aiur.Accounts",
    # Account windows come from the existing in-memory observation store.
    "Aiur.Accounts.UsageReadings",
    # Provider families and credential metadata come from the registry.
    "Aiur.CodingAgent",
    # ElevenLabs reads its supervised quota snapshot; it does not issue requests.
    "Aiur.ElevenLabs.Quota",
    # GitHub reads its supervised quota snapshot and existing resource holds.
    "Aiur.GitHub.Quota",
    # Durable previous-boot readings come from the existing local ledger file.
    "Aiur.ModelAvailability",
    # Watch events register the socket pid with the existing focused polling service.
    "Aiur.ProviderMeterRefresh",
    # The payload-free financial facade update identifies the coalesced reload.
    "AiurWeb.FinancialData",
    # Provider visibility reuses the registry credential filter without exporting keys.
    "AiurWeb.OperatorControlCenter.ModelProviders",
    # Credit balances reuse the existing amount formatter.
    "AiurWeb.OperatorControlCenter.Money",
    # Protected meter reads and subscriptions remain behind the financial facade.
    "AiurWeb.OperatorControlCenter.ProviderMeterSource",
    # Meter states and windows reuse the existing redacted presenter.
    "AiurWeb.OperatorControlCenter.ProviderMetersPresenter",
    # Build and Stream Deck share the same pure window classification.
    "AiurWeb.ProviderMeterWindows"
  ]
  # MP-E8-C11-T06 sends through the drawer's shared operator-message helper (AgentChat underneath).
  @shell ~w(AgentLogModal UnitsRow UnitsControlPolicy UnitsPresentation DecisionCommands DashboardShell NavState AwaitingCommands RouteRegistry OperatorSend)

  test "web side references only the seam (future regression guard)" do
    files = [Path.join(@root, "lib/aiur_web/live/build_live.ex")] ++ Path.wildcard(Path.join(@root, "lib/aiur_web/build/**/*.ex"))
    assert [_ | _] = files
    assert Enum.all?(files, &File.regular?/1)
    # C8-T03 reads the existing nonblocking snapshot facade with cadence-aware tolerance.
    # Keep these reader dependencies confined to Freshness, not the rest of the web seam.
    freshness = Path.join(@root, "lib/aiur_web/build/freshness.ex")
    # MP-E8-C11-T03 confines workspace, snapshot and live-history reads to the
    # replaceable wave-0b adapter; controllers still use ConversationSource.
    conversation = Path.join(@root, "lib/aiur_web/build/conversation_source/wave0b.ex")
    adapter_facades = ~w(Aiur.Conversation.History Aiur.Workspace.Layout Aiur.Config Aiur.Orchestrator Aiur.Tracker)
    # C11-T02 confines issue identity lookup to the open-ticket snapshot facade;
    # only the document presenter subscribes to detail updates and renders Markdown.
    document = Path.join(@root, "lib/aiur_web/build/ticket_doc.ex")
    identity = Path.join(@root, "lib/aiur_web/build/ticket_doc_identity.ex")
    assert offenders(files -- [freshness, conversation, document, identity], &allowed?/1) == []
    assert offenders([document], &(allowed?(&1) or &1 in ~w(Aiur.PubSub AiurWeb.Markdown))) == []
    assert offenders([identity], &(allowed?(&1) or &1 == "Aiur.OpenTicketSource")) == []
    assert offenders([conversation], &(allowed?(&1) or &1 in adapter_facades)) == []
    assert offenders([freshness], &(allowed?(&1) or &1 in ~w(Aiur.Orchestrator Aiur.PollCadence))) == []
  end

  test "stores do not reference AiurWeb (future regression guard)" do
    # ponytail: zero files is allowed until history and features stores land; then scan them too.
    files = for store <- ~w(history features), pattern <- ["#{store}.ex", "#{store}/**/*.ex"], file <- Path.wildcard(Path.join(@root, "lib/aiur/build_order/#{pattern}")), do: file
    assert offenders(files, &(not String.starts_with?(&1, "AiurWeb"))) == []
  end

  test "scanner expands grouped aliases and string modules and skips whole-line comments" do
    source = "alias AiurWeb.{Build, DashboardLive}\n\"Elixir.Aiur.Orchestrator\"\n  # see AiurWeb.DashboardLive"
    assert references(source) == [{1, "AiurWeb.Build"}, {1, "AiurWeb.DashboardLive"}, {2, "Aiur.Orchestrator"}]
    assert references("alias AiurWeb.{\n  Build,\n  DashboardLive\n}") == [{2, "AiurWeb.Build"}, {3, "AiurWeb.DashboardLive"}]
    assert references("Module.concat([Aiur.Orchestrator, State])") == [{1, "Aiur.Orchestrator.State"}]
    assert references(~s|Module.concat([AiurWeb, "DashboardLive"])|) == [{1, "AiurWeb.DashboardLive"}]
    refute allowed?("AiurWeb.DashboardLive")
    refute allowed?("Aiur.Orchestrator")
    assert allowed?("AiurWeb.OperatorControlCenter.UnitsRow.Cell")
  end

  defp offenders(files, allowed) do
    for file <- files, {line, module} <- references(File.read!(file)), not allowed.(module), do: {Path.relative_to(file, @root), line, module}
  end

  defp references(source) do
    source
    |> String.replace(~r/^[\t ]*#.*$/m, "")
    |> expand_grouped_aliases()
    |> expand_module_concat()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {text, line} ->
      for [module] <- Regex.scan(~r/\b(?:AiurWeb|Aiur)(?:\.[A-Z]\w*)+/, text), do: {line, module}
    end)
  end

  defp expand_grouped_aliases(source) do
    Regex.replace(~r/((?:AiurWeb|Aiur)(?:\.[A-Z]\w*)*)\.\{([^}]+)\}/, source, fn _, prefix, members ->
      Regex.replace(~r/[A-Z]\w*(?:\.[A-Z]\w*)*/, members, fn member -> prefix <> "." <> member end)
    end)
  end

  defp expand_module_concat(source) do
    Regex.replace(~r/Module\.concat\(\[?([^\]\)]+)\]?\)/, source, fn _, parts ->
      Regex.scan(~r/(?:Elixir\.)?[A-Z]\w*(?:\.[A-Z]\w*)*/, parts)
      |> List.flatten()
      |> Enum.map_join(".", &String.replace_prefix(&1, "Elixir.", ""))
    end)
  end

  defp allowed?(module) do
    module in @allowed or module in @usage_facades or module == "AiurWeb.Build" or String.starts_with?(module, "AiurWeb.Build.") or
      String.starts_with?(module, "Aiur.BuildOrder.") or
      Enum.any?(@shell, fn name ->
        base = "AiurWeb.OperatorControlCenter." <> name
        module == base or (name == "UnitsRow" and String.starts_with?(module, base <> "."))
      end)
  end
end
