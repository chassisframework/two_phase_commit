defmodule TwoPhaseCommit.Generators do
  use PropCheck

  def transaction do
    let [participants <- at_least_two(participants()),
         id <- id(),
         client <- client()] do
      TwoPhaseCommit.new(participants, id: id, client: client)
    end
  end

  def transaction_with_too_few_participants do
    let [participants <- at_most_one(participants()),
         id <- id(),
         client <- client()] do
      TwoPhaseCommit.new(participants, id: id, client: client)
    end
  end

  # PropCheck starts with size = 1, so we're basically starting it at 2
  def at_least_two(list_type) do
    sized(size, resize(size + 1, list_type))
  end

  def at_most_one(list_type) do
    let size <- integer(0, 1) do
      resize(size, list_type)
    end
  end

  def participants(current_participants \\ []) do
    unique_list_of(participant(), current_participants)
  end

  def participant do
    any()
  end

  def id do
    any()
  end

  def client do
    any()
  end


  defp unique_list_of(generator, current_things, unique_by \\ &(&1)) do
    sized(size, do_unique_list_of(size, generator, unique_by, [], current_things))
  end

  defp do_unique_list_of(0, _generator, _unique_by, things, _current_thing) do
    things
  end

  defp do_unique_list_of(size, generator, unique_by, things, current_things) do
    let thing <- new_unique_thing(generator, current_things, unique_by) do
      do_unique_list_of(size - 1, generator, unique_by, [thing | things], [thing | current_things])
    end
  end

  # TODO: this is really slow, O(N)
  defp new_unique_thing(generator, current, unique_by) do
    such_that thing <- generator, when:
    !Enum.any?(current, fn current_thing ->
      unique_by.(current_thing) === unique_by.(thing)
    end)
  end
end
