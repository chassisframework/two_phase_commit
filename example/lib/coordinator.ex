#
# Note: this is not a robust coordinator implementation, it lacks durable state,
#       high availability, crash recovery and participant polling. this is only
#       intended as a bare-bones demonstration of how to use the state maachine.
#
defmodule Coordinator do
  use GenServer

  def start_link do
    GenServer.start_link(__MODULE__, nil)
  end

  def transaction(coordinator, fun) do
    {:ok, txn_id} = GenServer.call(coordinator, {:begin, self()})

    result = fun.(txn_id)

    :ok = GenServer.call(coordinator, :prepare)

    receive do
      {:committed, ^txn_id} ->
        {:ok, result}

      {:aborted, ^txn_id} ->
        {:error, :aborted}
    end
  end

  def add_participant(coordinator, participant) do
    GenServer.call(coordinator, {:add_participant, participant})
  end

  def prepared(coordinator, participant) do
    GenServer.cast(coordinator, {:prepared, participant})
  end

  def aborted(coordinator, participant) do
    GenServer.cast(coordinator, {:aborted, participant})
  end

  def rolled_back(coordinator, participant) do
    GenServer.cast(coordinator, {:rolled_back, participant})
  end

  def committed(coordinator, participant) do
    GenServer.cast(coordinator, {:committed, participant})
  end

  @impl true
  def init(nil) do
    {:ok, :ready}
  end

  @impl true
  def handle_call({:begin, client}, _from, :ready) do
    txn_id = self()
    two_phase_commit = TwoPhaseCommit.new([], id: txn_id, client: client)

    {:reply, {:ok, txn_id}, two_phase_commit}
  end

  def handle_call({:add_participant, participant}, _from, two_phase_commit) do
    {:reply, :ok, TwoPhaseCommit.add_participant(two_phase_commit, participant)}
  end

  def handle_call(:prepare, _from, two_phase_commit) do
    {:ok, two_phase_commit} = TwoPhaseCommit.prepare(two_phase_commit)

    two_phase_commit
    |> TwoPhaseCommit.participants()
    |> Enum.each(&GenServer.cast(&1, {:prepare, self()}))

    {:reply, :ok, two_phase_commit}
  end

  @impl true
  def handle_cast({:prepared, participant}, two_phase_commit) do
    {:ok, two_phase_commit} = TwoPhaseCommit.prepared(two_phase_commit, participant)

    case TwoPhaseCommit.next_action(two_phase_commit) do
      {:commit, participants} ->
        Enum.each(participants, &GenServer.cast(&1, {:commit, self()}))

      _ ->
        :ok
    end

    {:noreply, two_phase_commit}
  end

  def handle_cast({:aborted, participant}, two_phase_commit) do
    {:ok, two_phase_commit} = TwoPhaseCommit.aborted(two_phase_commit, participant)

    #
    # we send a raw message here because we don't assume that all participants are Accounts
    #
    two_phase_commit
    |> TwoPhaseCommit.participants()
    |> Enum.each(&GenServer.cast(&1, {:roll_back, self()}))

    {:noreply, two_phase_commit}
  end

  def handle_cast({:rolled_back, participant}, %TwoPhaseCommit{id: id, client: client} = two_phase_commit) do
    {:ok, two_phase_commit} = TwoPhaseCommit.rolled_back(two_phase_commit, participant)

    case two_phase_commit do
      %TwoPhaseCommit{state: :aborted} ->
        send(client, {:aborted, id})
        {:stop, :normal, two_phase_commit}

      _ ->
        {:noreply, two_phase_commit}
    end
  end

  def handle_cast({:committed, participant}, %TwoPhaseCommit{id: id, client: client} = two_phase_commit) do
    {:ok, two_phase_commit} = TwoPhaseCommit.committed(two_phase_commit, participant)

    case two_phase_commit do
      %TwoPhaseCommit{state: :committed} ->
        send(client, {:committed, id})
        {:stop, :normal, two_phase_commit}

      _ ->
        {:noreply, two_phase_commit}
    end
  end
end
