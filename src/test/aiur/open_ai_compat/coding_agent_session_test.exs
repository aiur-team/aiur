defmodule Aiur.OpenAICompat.CodingAgentSessionTest do
  use ExUnit.Case, async: true
  use Aiur.TestSupport.OpenAICompatAgent

  alias Aiur.OpenAICompat.{CodingAgent, Config}

  test "named API key accounts resolve from the machine env file without leaking into session metadata", _context do
    home = Path.join(System.tmp_dir!(), "aiur-api-account-#{System.unique_integer([:positive])}")
    env_path = Path.join(home, ".aiur/.env")
    File.mkdir_p!(Path.dirname(env_path))
    File.write!(env_path, "DEEPSEEK_API_KEY__WORK=account-secret\nDEEPSEEK_API_KEY=default-secret\n")
    previous = System.get_env("HOME")
    System.put_env("HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("HOME", previous), else: System.delete_env("HOME")
      File.rm_rf!(home)
    end)

    config = %{
      base_url: "https://example.invalid/v1",
      api_key_env: "DEEPSEEK_API_KEY",
      default_model: "deepseek-v4-flash",
      transport: :responses,
      quirks: %{}
    }

    assert {:ok, resolved} =
             Config.resolve(
               backend: "deepseek",
               instance: config,
               backend_config: %{},
               account_name: "work"
             )

    assert resolved.api_key == "account-secret"
    refute inspect(Map.drop(resolved, [:api_key])) =~ "account-secret"
  end

  test "adapter uses the selected account key for its request", %{workspace: workspace} do
    home = Path.join(System.tmp_dir!(), "aiur-api-account-adapter-#{System.unique_integer([:positive])}")
    env_path = Path.join(home, ".aiur/.env")
    File.mkdir_p!(Path.dirname(env_path))
    File.write!(env_path, "DEEPSEEK_API_KEY__WORK=selected-secret\nDEEPSEEK_API_KEY=default-secret\n")
    previous = System.get_env("HOME")
    System.put_env("HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("HOME", previous), else: System.delete_env("HOME")
      File.rm_rf!(home)
    end)

    parent = self()

    request_fun = fn request ->
      send(parent, {:request, request})
      response(%{"id" => "selected-key", "choices" => [%{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "ok"}}]})
    end

    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: "deepseek",
               instance: %{instance([]) | api_key_env: "DEEPSEEK_API_KEY"},
               account_name: "work",
               request_fun: request_fun
             )

    assert {:ok, %{result: :turn_completed}} = CodingAgent.run_turn(session, "Use selected key", issue(), [])
    assert_receive {:request, request}, 1000
    assert request.headers["authorization"] == "Bearer selected-secret"
    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end

  test "normalizes provider errors without retaining a credential", %{workspace: workspace} do
    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: "kimi",
               instance: instance([]),
               api_key_fetcher: fn _ -> "credential-that-must-not-leak" end,
               request_fun: fn _ ->
                 {:ok,
                  %{
                    status: 500,
                    body: %{"error" => %{"message" => "provider failed"}},
                    headers: %{}
                  }}
               end
             )

    assert {:error, {:http_error, 500, "provider failed"}} =
             CodingAgent.run_turn(session, "trigger failure", issue(), [])

    refute inspect(session) =~ "credential-that-must-not-leak"
    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end

  test "rejects incomplete Responses and token-limited chat completions", %{workspace: workspace} do
    cases = [
      {:responses,
       %{
         "id" => "resp-incomplete",
         "status" => "incomplete",
         "output" => [],
         "incomplete_details" => %{"reason" => "max_output_tokens"}
       }, {:incomplete_provider_response, "incomplete"}},
      {:chat_completions,
       %{
         "id" => "chat-limited",
         "choices" => [
           %{
             "finish_reason" => "length",
             "message" => %{"role" => "assistant", "content" => "partial"}
           }
         ]
       }, {:incomplete_provider_response, "length"}}
    ]

    for {transport, body, reason} <- cases do
      assert {:ok, session} =
               CodingAgent.start_session(workspace,
                 backend: "deepseek",
                 instance: %{instance([]) | transport: transport},
                 api_key_fetcher: fn _ -> "secret" end,
                 request_fun: fn _request -> response(body) end
               )

      assert {:error, ^reason} = CodingAgent.run_turn(session, "Finish fully", issue(), [])
      assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
    end
  end

  test "session startup rejects the workspace root, outside paths, and symlink escapes" do
    root = Aiur.TestSupport.tmp_root!("aiur-openai-root")

    outside = Aiur.TestSupport.tmp_root!("aiur-openai-outside")

    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(root, "escaped"))
    on_exit(fn -> File.rm_rf!(root) end)
    on_exit(fn -> File.rm_rf!(outside) end)

    opts = [
      backend: "kimi",
      instance: instance([]),
      workspace_root: root,
      api_key_fetcher: fn _ -> "secret" end
    ]

    assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
             CodingAgent.start_session(root, opts)

    assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
             CodingAgent.start_session(outside, opts)

    assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
             CodingAgent.start_session(Path.join(root, "escaped"), opts)
  end

  test "backend config failures remain visible", %{workspace: workspace} do
    assert {:error, {:backend_config_unavailable, "configuration unavailable"}} =
             CodingAgent.start_session(workspace,
               backend: "kimi",
               instance: instance([]),
               backend_config_fetcher: fn _backend ->
                 raise "configuration unavailable"
               end,
               api_key_fetcher: fn _ -> "secret" end
             )
  end
end
