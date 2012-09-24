-module(throughput).

-export([start_counter/0, start_count/3, counter/0, count/3, nats/1]).

nats(0) ->
  [];
nats(N) ->
  [N | nats(N - 1)].

counter() ->
  counter(0).

counter(N) ->
  receive
    {count, List} ->
      counter(N + length(List));
    {get, Them} ->
      Them ! N,
      counter(0)
  end.
 
replicate(0, _) ->
  ok;
replicate(N, What) ->
  What(),
  replicate(N - 1, What).

count(Packets, Size, Them) ->
  replicate(Packets, fun() -> {counter, Them} ! {count, nats(Size)} end),
  {counter, Them} ! {get, self()},
  receive 
    N -> io:format("Did ~B pings", [N])
  end.

start_counter() ->
  register(counter, spawn(throughput, counter, [])).

start_count(Packets, Size, Them) ->
  count(Packets, Size, Them).
