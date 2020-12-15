defmodule TwoPhaseCommit do
  @moduledoc """
  A simple state machine representing the state of a two-phase commit, as well as providing
  next steps to be taken in the case of a coordinator recovery after a crash.
  """

  @type id :: any
  @type client :: any
  @type participant :: any
  @type participants :: [participant]
  @type state :: :interactive | {:voting | :rolling_back | :committing, MapSet.t(participant)} | :aborted | :committed
  @type next_action :: :write_data | {:vote | :roll_back | :commit, participants} | nil

  @type opt :: {:client, client} | {:id, id}
  @type opts :: [opt]

  @type t :: %__MODULE__{
    id: id,
    client: client,
    state: state,
    participants: MapSet.t()
  }

  defstruct [
    :id,
    :client,
    state: :interactive,
    participants: MapSet.new()
  ]


  @doc """
  Creates a new TwoPhaseCommit state structs with the given `participants`.

  The following keyword parameters can be provided:

  `:id` - stores the transaction id (globally unique)
  `:client` - stores an arbitrary identifying the requesting entity (a pid, etc)
  """
  @spec new(participants, opts) :: t
  def new(participants, opts \\ []) when is_list(participants) and is_list(opts) do
    id = Keyword.get(opts, :id, nil)
    client = Keyword.get(opts, :client, nil)

    %__MODULE__{
      id: id,
      client: client,
      participants: MapSet.new(participants)
    }
  end

  @doc """
  Adds a participant to the transaction while it's in the interactive phase.
  """
  @spec add_participant(t, participant) :: t
  def add_participant(%__MODULE__{participants: participants, state: :interactive} = two_phase_commit, participant) do
    %__MODULE__{
      two_phase_commit |
      participants: MapSet.put(participants, participant)
    }
  end

  # TODO better error
  def add_participant(%__MODULE__{}, _participant) do
    raise "particpants can only be added while transaction is interactive phase"
  end

  @doc """
  Returns a list of all participants.
  """
  @spec participants(t) :: participants
  def participants(%__MODULE__{participants: participants}) do
    MapSet.to_list(participants)
  end


  @doc """
  Indicates what actions need to be performed next in order to move the transaction forward.

  This is useful for the coordinator to determine where the transaction left off after recovering
  from a crash.
  """
  @spec next_action(t) :: next_action
  def next_action(%__MODULE__{state: :interactive}) do
    :write_data
  end

  def next_action(%__MODULE__{state: {:voting, awaiting_acknowledgement}}) do
    {:vote, MapSet.to_list(awaiting_acknowledgement)}
  end

  def next_action(%__MODULE__{state: {:rolling_back, awaiting_acknowledgement}}) do
    {:roll_back, MapSet.to_list(awaiting_acknowledgement)}
  end

  def next_action(%__MODULE__{state: {:committing, awaiting_acknowledgement}}) do
    {:commit, MapSet.to_list(awaiting_acknowledgement)}
  end

  def next_action(%__MODULE__{state: :aborted}), do: nil
  def next_action(%__MODULE__{state: :committed}), do: nil


  @doc """
  Moves the transaction to the voting phase.
  """
  @spec prepare(t) :: {:ok, t} | {:error, any()}
  def prepare(%__MODULE__{state: :interactive, participants: participants} = two_phase_commit) do
    if MapSet.size(participants) > 1 do
      {:ok, %__MODULE__{two_phase_commit | state: {:voting, participants}}}
    else
      {:error, :too_few_participants}
    end
  end

  @doc """
  Moves the transaction to the voting phase. Raises an error when there aren't enough participants.
  """
  @spec prepare!(t) :: t | no_return()
  def prepare!(%__MODULE__{} = two_phase_commit) do
    case prepare(two_phase_commit) do
      {:ok, two_phase_commit} ->
        two_phase_commit

      {:error, _} ->
        raise "too few participants, must have at least two."
    end
  end

  @doc """
  Records a participant's "prepared" vote, moves to the committing phase when all are prepared.
  """
  @spec prepared(t, participant) :: t | {:error, :unknown_participant}
  # votes that arrive after the we've decided to abort are ignored
  def prepared(%__MODULE__{state: {:rolling_back, _}} = two_phase_commit, participant) do
    with :ok <- known_participant(two_phase_commit, participant) do
      two_phase_commit
    end
  end

  def prepared(%__MODULE__{state: {:voting, awaiting_votes}, participants: participants} = two_phase_commit, participant) do
    with :ok <- known_participant(two_phase_commit, participant) do
      awaiting_votes = MapSet.delete(awaiting_votes, participant)

      state =
        if MapSet.size(awaiting_votes) == 0 do
          {:committing, participants}
        else
          {:voting, awaiting_votes}
        end

      %__MODULE__{two_phase_commit | state: state}
    end
  end

  @doc """
  Records a participant's "abort" vote and moves the transaction to the rolling_back state.
  """
  @spec aborted(t, participant) :: t | {:error, :unknown_participant}
  def aborted(%__MODULE__{state: {:voting, awaiting_votes}, participants: participants} = two_phase_commit, participant) do
    with :ok <- known_participant(two_phase_commit, participant) do
      state =
        if MapSet.member?(awaiting_votes, participant) do
          {:rolling_back, participants}
        else
          raise "participant already voted to commit"
        end

      %__MODULE__{two_phase_commit | state: state}
    end
  end

  def aborted(%__MODULE__{state: {:rolling_back, _awaiting}} = two_phase_commit, _participant) do
    two_phase_commit
  end

  @doc """
  Notes that a participant has rolled back, moves to the aborted state when all have rolled back.
  """
  @spec rolled_back(t, participant) :: t | {:error, :unknown_participant}
  def rolled_back(%__MODULE__{state: {:rolling_back, awaiting_acknowledgment}} = two_phase_commit, participant) do
    with :ok <- known_participant(two_phase_commit, participant) do
      awaiting_acknowledgment = MapSet.delete(awaiting_acknowledgment, participant)

      state =
        if MapSet.size(awaiting_acknowledgment) == 0 do
          :aborted
        else
          {:rolling_back, awaiting_acknowledgment}
        end

      %__MODULE__{two_phase_commit | state: state}
    end
  end

  @doc """
  Notes that a participant has committed, moves to the committed state when all have committed.
  """
  @spec committed(t, participant) :: t | {:error, :unknown_participant}
  def committed(%__MODULE__{state: {:committing, awaiting_acknowledgement}} = two_phase_commit, participant) do
    with :ok <- known_participant(two_phase_commit, participant) do
      awaiting_acknowledgement = MapSet.delete(awaiting_acknowledgement, participant)

      state =
        if MapSet.size(awaiting_acknowledgement) == 0 do
          :committed
        else
          {:committing, awaiting_acknowledgement}
        end

      %__MODULE__{two_phase_commit | state: state}
    end
  end

  defp known_participant(%__MODULE__{participants: participants}, participant) do
    if MapSet.member?(participants, participant) do
      :ok
    else
      # TODO proper error
      {:error, :unknown_participant}
    end
  end
end
