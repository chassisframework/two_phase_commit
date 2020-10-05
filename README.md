# TwoPhaseCommit

*WORK IN PROGRESS*

[Two Phase Commit](https://en.wikipedia.org/wiki/Two-phase_commit_protocol) state machine model.

You can use the state machine to build a transaction coordinator, there's a bare-bones GenServer [implementation](example/lib/coordinator.ex) included.

## Installation

The package can be installed by adding `two_phase_commit` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:two_phase_commit, "~> 0.1.0"}
  ]
end
```

The docs can be found at [https://hexdocs.pm/two_phase_commit](https://hexdocs.pm/two_phase_commit).

## State Machine Diagram

```

                             +
                             |
                             | new/2
                             |
                             v
                     +-------+------+
                  +--+              |
add_participant/2 |  | :interactive |
                  +->+              |                aborted/2
                     +-------+------+
                             |                       +------+
                             | prepare/1             |      |
                             v                       |      v
                     +-------+------+           +----+------+---+               +---------------+
                  +--+              | aborted/2 |               | rolled_back/2 |               |
       prepared/2 |  |   :voting    +---------->+ :rolling_back +-------------->+   :aborted    |
                  +->+              |           |               |               |               |
                     +-------+------+           +----+------+---+               +---------------+
                             |                       |      ^
                             | prepared/2            |      |
                             v                       +------+
                     +-------+-------+
                  +--+               |             rolled_back/2
      committed/2 |  |  :committing  |
                  +->+               |
                     +-------+-------+
                             |
                             | committed/2
                             v
                     +-------+-------+
                     |               |
                     |  :committed   |
                     |               |
                     +---------------+

```
