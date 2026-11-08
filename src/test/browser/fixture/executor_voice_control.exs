defmodule Aiur.BrowserHarness.ExecutorVoiceControl do
  @moduledoc "Enables only the synthetic fixture workflow's Executor controls for browser coverage."
  use Phoenix.Controller, formats: []

  @original_key :browser_executor_voice_original_workflow

  def configure(conn, %{"mode" => "configured"}) do
    original = Application.get_env(:aiur, @original_key) || Aiur.Workflow.workflow_file_path()
    Application.put_env(:aiur, @original_key, original)
    directory = Path.join(System.tmp_dir!(), "executor-voice-browser-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    path = Path.join(directory, "test.yaml")
    voice = "\nvoice:\n  conversation:\n    provider: openai_realtime\n    llm: browser-model\n    cloud_disclosure_accepted: true\n"
    File.write!(path, File.read!(original) <> voice)
    Application.put_env(:aiur, :workflow_file_path, path)
    Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, true)
    Plug.Conn.send_resp(conn, 200, "synthetic Executor voice configured")
  end

  def configure(conn, %{"mode" => "reset"}) do
    if original = Application.get_env(:aiur, @original_key), do: Application.put_env(:aiur, :workflow_file_path, original)
    Plug.Conn.send_resp(conn, 200, "synthetic Executor voice reset")
  end

  def configure(conn, _params), do: Plug.Conn.send_resp(conn, 404, "unknown synthetic Executor voice mode")
end
