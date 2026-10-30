defmodule Aiur.ControlCLI.ExecutorAttach do
  @moduledoc false
  alias Aiur.Executor.AttachCLI
  alias Aiur.HttpServer

  @spec attach(keyword()) :: :ok
  def attach(opts), do: AttachCLI.attach(Keyword.put(opts, :bound_port, HttpServer.bound_port()))
end
