-module(throughput).

-export([start_counter/0, start_count/2, counter/0, count/2]).

counter() ->
  counter(0).

counter(N) ->
  receive
    nothing ->
      counter(N + 1);
    {just, Them} ->
      Them ! N,
      counter(0)
  end.
 
replicate(0, _) ->
  ok;
replicate(N, What) ->
  What(),
  replicate(N - 1, What).

count(N, Them) ->
  replicate(N, fun() -> {counter, Them} ! nothing end),
  {counter, Them} ! {just, self()},
  receive 
    N -> io:format("Did ~B pings", [N])
  end.

start_counter() ->
  register(counter, spawn(throughput, counter, [])).

start_count(N, Them) ->
  count(N, Them).
