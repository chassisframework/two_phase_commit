defprotocol TwoPhaseCommit.Participant do
  @fallback_to_any true

  @type id :: any()

  @doc "return the unique id for this participant"
  @spec id(t) :: id()
  def id(participant)

end

defimpl TwoPhaseCommit.Participant, for: Any do
  def id(participant), do: participant
end
