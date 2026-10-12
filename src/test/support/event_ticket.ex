defmodule Aiur.TestSupport.EventTicket do
  @moduledoc false
  # Fixture builders run in the test process; capture the ID before spawning callbacks.

  defmacro __using__(_opts) do
    quote do
      import Aiur.TestSupport.EventTicket

      setup do
        Process.put(Aiur.TestSupport.EventTicket, System.unique_integer([:positive]))
        :ok
      end
    end
  end

  def ticket_number, do: Process.get(__MODULE__)
  def ticket_id, do: Integer.to_string(ticket_number())
end
