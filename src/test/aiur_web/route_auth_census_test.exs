defmodule AiurWeb.RouteAuthCensusTest do
  @moduledoc """
  Authorization census consumed by MP-R4 and extended by MP-N2's pairing pipeline.
  These future-regression guards intentionally pass against existing production code.
  """

  use ExUnit.Case, async: true

  import Phoenix.ChannelTest, only: [socket: 3]

  @endpoint AiurWeb.Endpoint
  @authenticators [:dashboard_auth, :dashboard_auth_required, :supervisor_auth, :github_webhook]
  @audited_sockets %{
    "/live" => Phoenix.LiveView.Socket,
    "/streamdeck" => AiurWeb.StreamdeckSocket,
    "/voice" => AiurWeb.VoiceSocket
  }

  test "every declared route is reachable and includes an authenticator" do
    failures =
      for route <- Phoenix.Router.routes(AiurWeb.Router),
          method = if(route.verb == :*, do: "AIURCENSUS", else: route.verb |> to_string() |> String.upcase()),
          info = Phoenix.Router.route_info(AiurWeb.Router, method, route.path, "localhost"),
          info == :error or info.route != route.path or not Enum.any?(info.pipe_through, &(&1 in @authenticators)) do
        {route.verb, route.path, info}
      end

    assert failures == [], "Unreachable or unauthenticated routes: #{inspect(failures, pretty: true, limit: :infinity)}"
  end

  test "the endpoint mounts exactly the audited socket paths and modules" do
    # __sockets__/0 is @doc false, but Phoenix.ChannelTest and ConsoleFormatter
    # also use it; a Phoenix upgrade removing it must force a fresh endpoint audit.
    mounted = for {path, module, _opts} <- AiurWeb.Endpoint.__sockets__(), do: {path, module}
    assert Enum.sort(mounted) == Enum.sort(@audited_sockets)
  end

  test "audited channel sockets reject a connection without proof" do
    # /live accepts connect by design; FinancialDataAccess on_mount is guarded
    # by financial_data_access_test.exs, including every dashboard LiveView route.
    for module <- [AiurWeb.StreamdeckSocket, AiurWeb.VoiceSocket] do
      assert :error == module.connect(%{}, socket(module, nil, %{}), %{}),
             "#{inspect(module)} accepted a connection without proof"
    end
  end
end
