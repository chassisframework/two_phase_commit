defmodule TwoPhaseCommitTest do
  use ExUnit.Case
  use PropCheck

  import TwoPhaseCommit.Generators
  # doctest TwoPhaseCommit

  describe "interactive phase" do
    property "next_actions/1 indicates that participants should write data" do
      forall txn <- transaction() do
        assert TwoPhaseCommit.next_action(txn) == :write_data
      end
    end

    property "add_participant/2" do
      forall [txn <- transaction(),
              new_participant <- participant()] do
        %TwoPhaseCommit{participants: participants} = txn
        %TwoPhaseCommit{participants: new_participants} = TwoPhaseCommit.add_participant(txn, new_participant)

        assert new_participants == MapSet.put(participants, new_participant)
      end
    end

    property "prepare/1 moves to voting phase" do
      forall txn <- transaction() do
        txn = TwoPhaseCommit.prepare(txn)

        assert %TwoPhaseCommit{state: {:voting, voting}} = txn
        assert MapSet.to_list(voting) == TwoPhaseCommit.participants(txn)
      end
    end

    property "prepare/1 raises when there aren't enough participants" do
      forall txn <- transaction_with_too_few_participants() do
        assert_raise(RuntimeError, ~r/at least two/, fn ->
          TwoPhaseCommit.prepare(txn)
        end)

        true
      end
    end
  end

  describe "voting phase" do
    property "next_actions/1 indicates that participants should vote" do
      forall txn <- transaction() do
        txn = TwoPhaseCommit.prepare(txn)

        assert TwoPhaseCommit.next_action(txn) == {:vote, TwoPhaseCommit.participants(txn)}
      end
    end

    property "prepared/2 continues the voting phase" do
      forall txn <- transaction() do
        [prepared | rest] = TwoPhaseCommit.participants(txn)

        txn =
          txn
          |> TwoPhaseCommit.prepare()
          |> TwoPhaseCommit.prepared(prepared)

        assert %TwoPhaseCommit{state: {:voting, voting}} = txn
        assert voting == MapSet.new(rest)
      end
    end

    property "prepared/2 moves to the :committing phase when all participants are prepared" do
      forall txn <- transaction() do
        participants = TwoPhaseCommit.participants(txn)

        txn =
          txn
          |> TwoPhaseCommit.prepare()
          |> all_prepared(participants)

        assert %TwoPhaseCommit{state: {:committing, committing}} = txn
        assert committing == MapSet.new(participants)
      end
    end
  end

  describe "abort during voting phase" do
    property "aborted/2 moves to the :rolling_back state when any participant aborts" do
      forall txn <- transaction() do
        [will_abort | rest] = participants = TwoPhaseCommit.participants(txn)

        txn =
          txn
          |> TwoPhaseCommit.prepare()
          |> all_prepared(rest)
          |> TwoPhaseCommit.aborted(will_abort)

        assert %TwoPhaseCommit{state: {:rolling_back, rolling_back}} = txn
        assert rolling_back == MapSet.new(participants)
      end
    end

    property "aborts from multiple participants still moves to :rolling_back state" do
      forall txn <- transaction() do
        [prepared | rest] = participants = TwoPhaseCommit.participants(txn)

        txn =
          txn
          |> TwoPhaseCommit.prepare()
          |> TwoPhaseCommit.prepared(prepared)
          |> all_aborted(rest)

        assert %TwoPhaseCommit{state: {:rolling_back, rolling_back}} = txn
        assert rolling_back == MapSet.new(participants)
      end
    end

    property "next_action/1 indicates that all participants should roll back" do
      forall txn <- transaction() do
        [will_abort | rest] = participants = TwoPhaseCommit.participants(txn)

        txn =
          txn
          |> TwoPhaseCommit.prepare()
          |> all_prepared(rest)
          |> TwoPhaseCommit.aborted(will_abort)

        assert TwoPhaseCommit.next_action(txn) == {:roll_back, participants}
      end
    end

    property "aborted/2 moves to the final :aborted state when all participants have rolled back" do
      forall txn <- transaction() do
        [will_abort | rest] = participants = TwoPhaseCommit.participants(txn)

        txn =
          txn
          |> TwoPhaseCommit.prepare()
          |> all_prepared(rest)
          |> TwoPhaseCommit.aborted(will_abort)
          |> all_rolled_back(participants)

        assert %TwoPhaseCommit{state: :aborted} = txn

        true
      end
    end
  end

  describe "commitment phase" do
    property "next_action/1 indicates that all participants should commit" do
      forall txn <- transaction() do
        participants = TwoPhaseCommit.participants(txn)

        txn =
          txn
          |> TwoPhaseCommit.prepare()
          |> all_prepared(participants)

        assert TwoPhaseCommit.next_action(txn) == {:commit, participants}
      end
    end

    property "committed/2 continues the commitment phase" do
      forall txn <- transaction() do
        [will_commit | rest] = participants = TwoPhaseCommit.participants(txn)

        txn =
          txn
          |> TwoPhaseCommit.prepare()
          |> all_prepared(participants)
          |> TwoPhaseCommit.committed(will_commit)

        assert %TwoPhaseCommit{state: {:committing, committing}} = txn
        assert committing == MapSet.new(rest)
      end
    end

    property "committed/2 moves to the final :committed state when all participants have committed" do
      forall txn <- transaction() do
        participants = TwoPhaseCommit.participants(txn)

        txn =
          txn
          |> TwoPhaseCommit.prepare()
          |> all_prepared(participants)
          |> all_committed(participants)

        assert %TwoPhaseCommit{state: :committed} = txn

        true
      end
    end
  end

  defp all_prepared(txn, participants) do
    all(txn, participants, &TwoPhaseCommit.prepared/2)
  end

  defp all_aborted(txn, participants) do
    all(txn, participants, &TwoPhaseCommit.aborted/2)
  end

  defp all_rolled_back(txn, participants) do
    all(txn, participants, &TwoPhaseCommit.rolled_back/2)
  end

  defp all_committed(txn, participants) do
    all(txn, participants, &TwoPhaseCommit.committed/2)
  end

  defp all(txn, participants, func) do
    Enum.reduce(participants, txn, fn x, acc -> func.(acc, x) end)
  end
end
