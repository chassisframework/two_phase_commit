defmodule Account do
  use GenServer

  require Logger

  defmodule State do
    defstruct [
      value: 0,
      staged_value: 0,
      coordinator: nil
    ]
  end

  def start_link(amount) do
    GenServer.start_link(__MODULE__, amount)
  end

  def value(account, txn_id) do
    GenServer.call(account, {:value, txn_id})
  end

  def increment(account, amount, txn_id) do
    GenServer.call(account, {:adjust, amount, txn_id})
  end

  def decrement(account, amount, txn_id) do
    increment(account, amount * -1, txn_id)
  end


  @impl true
  def init(value) do
    {:ok, %State{value: value}}
  end

  # read lock
  @impl true
  def handle_call({:value, txn_id}, _from, %State{coordinator: coordinator, value: value} = state) when is_nil(coordinator) or coordinator == txn_id do
    {:reply, {:ok, value}, %State{state | coordinator: txn_id}}
  end

  # write lock
  def handle_call({:adjust, amount, txn_id}, _from, %State{coordinator: coordinator, value: value} = state) when is_nil(coordinator) or coordinator == txn_id do

    Logger.info "Account #{inspect self()} staging adjustment #{amount}."

    :ok = Coordinator.add_participant(txn_id, self())

    state =
      %State{
        state |
        staged_value: value + amount,
        coordinator: txn_id
      }

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:prepare, coordinator}, %State{coordinator: coordinator} = state) do
    if :rand.normal > 0 do
      Logger.info "Account #{inspect self()} voting to abort."

      Coordinator.aborted(coordinator, self())
    else
      Logger.info "Account #{inspect self()} voting to commit."

      Coordinator.prepared(coordinator, self())
    end

    {:noreply, state}
  end

  def handle_cast({:roll_back, coordinator}, %State{coordinator: coordinator} = state) do
    Logger.info "Account #{inspect self()} rolling back."

    Coordinator.rolled_back(coordinator, self())

    {:noreply, %State{state | coordinator: nil, staged_value: nil}}
  end
  def handle_cast({:roll_back, _coordinator}, state), do: {:noreply, state}

  def handle_cast({:commit, coordinator}, %State{coordinator: coordinator, staged_value: staged_value} = state) do
    Logger.info "Account #{inspect self()} committed."

    Coordinator.committed(coordinator, self())

    {:noreply, %State{state | coordinator: nil, staged_value: nil, value: staged_value}}
  end
end

