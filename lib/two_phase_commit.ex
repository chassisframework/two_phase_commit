defmodule TwoPhaseCommit do
  @moduledoc """
  A simple state machine representing the state of a two-phase commit, as well as providing
  next steps to be taken in the case of a coordinator recovery after a crash.
  """

  alias TwoPhaseCommit.Participant

  @type id :: any
  @type client :: any
  @type participant_ids :: [Participant.id()]
  @type participants :: %{Participant.id() => Participant.t()}
  @type state :: :interactive | {:voting | :rolling_back | :committing, participant_ids} | :aborted | :committed
  @type next_action :: :write_data | {:vote | :roll_back | :commit, participants} | nil

  @type opt :: {:client, client} | {:id, id}
  @type opts :: [opt]

  @type t :: %__MODULE__{
    id: id,
    client: client,
    state: state,
    participants: participants()
  }

  defstruct [
    :id,
    :client,
    state: :interactive,
    participants: %{}
  ]


  @doc """
  Creates a new TwoPhaseCommit state structs with the given `participants`.

  The following keyword parameters can be provided:

  `:id` - stores the transaction id (globally unique)
  `:client` - stores an arbitrary identifying the requesting entity (a pid, etc)
  """
  @spec new([Participant.t()], opts) :: t
  def new(participants, opts \\ []) when is_list(participants) and is_list(opts) do
    id = Keyword.get(opts, :id, nil)
    client = Keyword.get(opts, :client, nil)
    participants = Map.new(participants, fn participant -> {Participant.id(participant), participant} end)

    %__MODULE__{
      id: id,
      client: client,
      participants: participants
    }
  end

  @doc """
  Adds a participant to the transaction while it's in the interactive phase.
  """
  @spec add_participant(t, Participant.t()) :: t
  def add_participant(%__MODULE__{participants: participants, state: :interactive} = two_phase_commit, participant) do
    %__MODULE__{
      two_phase_commit |
      participants: Map.put(participants, Participant.id(participant), participant)
    }
  end

  # TODO better error
  def add_participant(%__MODULE__{}, _participant) do
    raise "particpants can only be added while transaction is interactive phase"
  end

  @doc """
  Returns a list of all participants.
  """
  @spec participants(t) :: [Participant.t()]
  def participants(%__MODULE__{participants: participants}) do
    Map.values(participants)
  end


  @doc """
  Indicates what actions need to be performed next in order to move the transaction forward.

  This is useful for the coordinator to determine where the transaction left off after recovering
  from a crash.
  """
  @spec next_action(t) :: next_action
  def next_action(%__MODULE__{state: :interactive}) do
    :prepare
  end

  def next_action(%__MODULE__{state: {:voting, awaiting_vote_ids}, participants: participants}) do
    {:vote, participants_for_ids(awaiting_vote_ids, participants)}
  end

  def next_action(%__MODULE__{state: {:rolling_back, awaiting_rollback_ids}, participants: participants}) do
    {:roll_back, participants_for_ids(awaiting_rollback_ids, participants)}
  end

  def next_action(%__MODULE__{state: {:committing, awaiting_commit_ids}, participants: participants}) do
    {:commit, participants_for_ids(awaiting_commit_ids, participants)}
  end

  def next_action(%__MODULE__{state: :aborted}), do: nil
  def next_action(%__MODULE__{state: :committed}), do: nil


  @doc """
  Moves the transaction to the voting phase.
  """
  @spec prepare(t) :: {:ok, t} | {:error, any()}
  def prepare(%__MODULE__{state: :interactive, participants: participants} = two_phase_commit) when map_size(participants) > 1 do
    {:ok, %__MODULE__{two_phase_commit | state: {:voting, participant_ids(two_phase_commit)}}}
  end

  def prepare(%__MODULE__{state: :interactive}) do
    {:error, :too_few_participants}
  end

  @doc false
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
  @spec prepared(t, Participant.t()) :: {:ok, t} | {:error, :unknown_participant}
  # votes that arrive after the we've decided to abort are ignored
  def prepared(%__MODULE__{state: {:rolling_back, _}} = two_phase_commit, participant) do
    with :ok <- known_participant(two_phase_commit, participant) do
      {:ok, two_phase_commit}
    end
  end

  def prepared(%__MODULE__{state: {:voting, awaiting_vote_ids}} = two_phase_commit, participant) do
    with :ok <- known_participant(two_phase_commit, participant) do
      awaiting_vote_ids = MapSet.delete(awaiting_vote_ids, Participant.id(participant))

      state =
        if Enum.empty?(awaiting_vote_ids) do
          {:committing, participant_ids(two_phase_commit)}
        else
          {:voting, awaiting_vote_ids}
        end

      {:ok, %__MODULE__{two_phase_commit | state: state}}
    end
  end

  @doc """
  Records a participant's "abort" vote and moves the transaction to the rolling_back state.
  """
  @spec aborted(t, Participant.t()) :: {:ok, t} | {:error, :unknown_participant}
  def aborted(%__MODULE__{state: {:voting, awaiting_vote_ids}} = two_phase_commit, participant) do
    with :ok <- known_participant(two_phase_commit, participant) do
      if not MapSet.member?(awaiting_vote_ids, Participant.id(participant)) do
        raise "participant already voted to commit"
      end

      {:ok, %__MODULE__{two_phase_commit | state: {:rolling_back, participant_ids(two_phase_commit)}}}
    end
  end

  def aborted(%__MODULE__{state: {:rolling_back, _awaiting}} = two_phase_commit, _participant) do
    {:ok, two_phase_commit}
  end

  @doc """
  Notes that a participant has rolled back, moves to the aborted state when all have rolled back.
  """
  @spec rolled_back(t, Participant.t()) :: {:ok, t} | {:error, :unknown_participant}
  def rolled_back(%__MODULE__{state: {:rolling_back, awaiting_rolledback_ids}} = two_phase_commit, participant) do
    with :ok <- known_participant(two_phase_commit, participant) do
      awaiting_rolledback_ids = MapSet.delete(awaiting_rolledback_ids, Participant.id(participant))

      state =
        if Enum.empty?(awaiting_rolledback_ids) do
          :aborted
        else
          {:rolling_back, awaiting_rolledback_ids}
        end

      {:ok, %__MODULE__{two_phase_commit | state: state}}
    end
  end

  @doc """
  Notes that a participant has committed, moves to the committed state when all have committed.
  """
  @spec committed(t, Participant.id()) :: {:ok, t} | {:error, :unknown_participant}
  def committed(%__MODULE__{state: {:committing, awaiting_committed_ids}} = two_phase_commit, participant) do
    with :ok <- known_participant(two_phase_commit, participant) do
      awaiting_committed_ids = MapSet.delete(awaiting_committed_ids, Participant.id(participant))

      state =
        if Enum.empty?(awaiting_committed_ids) do
          :committed
        else
          {:committing, awaiting_committed_ids}
        end

      {:ok, %__MODULE__{two_phase_commit | state: state}}
    end
  end

  defp known_participant(%__MODULE__{participants: participants}, participant) do
    if Map.has_key?(participants, Participant.id(participant)) do
      :ok
    else
      {:error, :unknown_participant}
    end
  end

  defp participant_ids(%__MODULE__{participants: participants}) do
    participants
    |> Map.keys()
    |> MapSet.new()
  end

  defp participants_for_ids(ids, participants) do
    Enum.map(ids, &Map.fetch!(participants, &1))
  end
end
