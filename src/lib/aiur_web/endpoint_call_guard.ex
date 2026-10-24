defmodule AiurWeb.EndpointCallGuard do
  @moduledoc false

  defmacro __before_compile__(_env) do
    quote do
      defoverridable call: 2

      def call(conn, opts) do
        conn = AiurWeb.HostAllowlist.call(conn, [])
        if conn.halted, do: conn, else: super(conn, opts)
      end
    end
  end
end
