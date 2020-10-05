defmodule Example do
  def run do
    {:ok, coordinator} = Coordinator.start_link()
    {:ok, account} = Account.start_link(1000)
    {:ok, other_account} = Account.start_link(1000)

    Coordinator.transaction(coordinator, fn txn_id ->
      {:ok, value} = Account.value(account, txn_id)
      amount_to_move = round(value / 2)

      :ok = Account.decrement(account, amount_to_move, txn_id)
      :ok = Account.increment(other_account, amount_to_move, txn_id)
    end)
    |> IO.inspect

    :sys.get_state(account)
    |> IO.inspect()

    :sys.get_state(other_account)
    |> IO.inspect()

    nil
  end
end
