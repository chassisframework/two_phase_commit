defmodule TwoPhaseCommitTest do
  use ExUnit.Case
  use PropCheck

  alias TwoPhaseCommit.Participant
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
              %TestParticipant{id: new_participant_id} = new_participant <- participant()] do
        %TwoPhaseCommit{participants: participants} = txn
        %TwoPhaseCommit{participants: new_participants} = TwoPhaseCommit.add_participant(txn, new_participant)

        assert new_participants == Map.put(participants, new_participant_id, new_participant)
      end
    end

    property "prepare/1 moves to voting phase" do
      forall txn <- transaction() do
        {:ok, txn} = TwoPhaseCommit.prepare(txn)

        voting_ids =
          txn
          |> TwoPhaseCommit.participants()
          |> participant_ids()

        assert %TwoPhaseCommit{state: {:voting, ^voting_ids}} = txn

        true
      end
    end

    property "prepare/1 returns an error when there aren't enough participants" do
      forall txn <- transaction_with_too_few_participants() do
        assert {:error, :too_few_participants} == TwoPhaseCommit.prepare(txn)
      end
    end
  end

  describe "voting phase" do
    property "next_actions/1 indicates that participants should vote" do
      forall txn <- transaction() do
        txn = TwoPhaseCommit.prepare!(txn)
        should_vote =
          txn
          |> TwoPhaseCommit.participants()
          |> MapSet.new()

        assert {:vote, voting} = TwoPhaseCommit.next_action(txn)
        assert MapSet.new(voting) == should_vote
      end
    end

    property "prepared/2 continues the voting phase" do
      forall txn <- transaction() do
        [to_prepare | _] = TwoPhaseCommit.participants(txn)

        {:ok, txn} =
          txn
          |> TwoPhaseCommit.prepare!()
          |> TwoPhaseCommit.prepared(to_prepare)

        assert %TwoPhaseCommit{state: {:voting, _}} = txn

        true
      end
    end

    property "prepared/2 moves to the :committing phase when all participants are prepared" do
      forall txn <- transaction() do
        participants = TwoPhaseCommit.participants(txn)

        txn =
          txn
          |> TwoPhaseCommit.prepare!()
          |> all_prepared(participants)

        assert %TwoPhaseCommit{state: {:committing, _}} = txn

        true
      end
    end
  end

  describe "abort during voting phase" do
    property "aborted/2 moves to the :rolling_back state when any participant aborts" do
      forall txn <- transaction() do
        [will_abort | rest] = TwoPhaseCommit.participants(txn)

        {:ok, txn} =
          txn
          |> TwoPhaseCommit.prepare!()
          |> all_prepared(rest)
          |> TwoPhaseCommit.aborted(will_abort)

        assert %TwoPhaseCommit{state: {:rolling_back, _}} = txn

        true
      end
    end

    property "aborts from multiple participants still moves to :rolling_back state" do
      forall txn <- transaction() do
        [prepared | rest] = TwoPhaseCommit.participants(txn)

        {:ok, txn} =
          txn
          |> TwoPhaseCommit.prepare!()
          |> TwoPhaseCommit.prepared(prepared)

        assert %TwoPhaseCommit{state: {:rolling_back, _}} = all_aborted(txn, rest)

        true
      end
    end

    property "next_action/1 indicates that all participants should roll back" do
      forall txn <- transaction() do
        [will_abort | rest] = participants = TwoPhaseCommit.participants(txn)

        {:ok, txn} =
          txn
          |> TwoPhaseCommit.prepare!()
          |> all_prepared(rest)
          |> TwoPhaseCommit.aborted(will_abort)

        assert {:roll_back, rolling_back} = TwoPhaseCommit.next_action(txn)
        assert MapSet.new(rolling_back) == MapSet.new(participants)
      end
    end

    property "aborted/2 moves to the final :aborted state when all participants have rolled back" do
      forall txn <- transaction() do
        [will_abort | rest] = participants = TwoPhaseCommit.participants(txn)

        txn =
          txn
          |> TwoPhaseCommit.prepare!()
          |> all_prepared(rest)

        {:ok, txn} = TwoPhaseCommit.aborted(txn, will_abort)

        assert %TwoPhaseCommit{state: :aborted} = all_rolled_back(txn, participants)

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
          |> TwoPhaseCommit.prepare!()
          |> all_prepared(participants)

        assert TwoPhaseCommit.next_action(txn) == {:commit, participants}
      end
    end

    property "committed/2 continues the commitment phase" do
      forall txn <- transaction() do
        [will_commit | _] = participants = TwoPhaseCommit.participants(txn)

        txn =
          txn
          |> TwoPhaseCommit.prepare!()
          |> all_prepared(participants)

        {:ok, txn} = TwoPhaseCommit.committed(txn, will_commit)

        assert %TwoPhaseCommit{state: {:committing, _}} = txn

        true
      end
    end

    property "committed/2 moves to the final :committed state when all participants have committed" do
      forall txn <- transaction() do
        participants = TwoPhaseCommit.participants(txn)

        txn =
          txn
          |> TwoPhaseCommit.prepare!()
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
    Enum.reduce(participants, txn, fn participant, txn ->
      {:ok, txn} = func.(txn, participant)

      txn
    end)
  end

  defp participant_ids(participants) do
    MapSet.new(participants, &Participant.id/1)
  end
end
