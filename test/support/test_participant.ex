defmodule TestParticipant do
  @moduledoc false

  defstruct [:id]

  defimpl TwoPhaseCommit.Participant do
    def id(%@for{id: id}), do: id
  end
end
