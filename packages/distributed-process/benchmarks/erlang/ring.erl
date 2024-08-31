%% can be run via escript if desired...
-module(ring).

-export([main/1]).

-record(opts, {
    ring_size  = 1 :: non_neg_integer(),
    iterations = 1 :: non_neg_integer()
}).

main(Argv) when is_list(Argv) ->
    Opts = parse_args(Argv),
    {Time, ok} = timer:tc(fun() -> run(Opts) end),
    io:format("elapsed (wallclock) time: ~pms~n", [Time / 1000]).

run(#opts{ ring_size=RingSize, iterations=SendCount }) ->
    Self = self(),
    Msg = {"foobar", "baz"},
    Pid = make_ring(RingSize, Self),
    [Pid ! Msg || _ <- lists:seq(1, SendCount)],
    collect(SendCount).

collect(0) ->
    ok;
collect(N) ->
    receive
        {"foobar", "baz"} -> collect(N - 1);
        Other             -> exit({unexpected_message, Other})
    end.

-spec(make_ring(integer(), pid()) -> pid()).
make_ring(0, NextPid) ->
    go(NextPid);
make_ring(NumProcs, NextPid) ->
    make_ring(NumProcs - 1, go(NextPid)).

-spec(go(pid()) -> pid()).
go(NextPid) ->
    spawn(fun() -> relay(NextPid) end).

-spec(relay(pid()) -> no_return()).
relay(NextPid) ->
    receive
        {_, _}=Msg -> NextPid ! Msg, relay(NextPid)
    end.

-spec(parse_args([string()]) -> #opts{}).
parse_args(Argv) ->
    lists:foldl(fun parse_args/2, #opts{}, Argv).

parse_args(("-r" ++ Val), Opts) ->
    Sz = check_positive(ring_size, list_to_integer(Val)),
    Opts#opts{ ring_size = Sz };
parse_args(("-i" ++ Val), Opts) ->
    Iter = check_positive(iterations, list_to_integer(Val)),
    Opts#opts{ iterations = Iter }.

check_positive(K, N) when N < 1 ->
    io:format("~p must be >= 1~n", [K]),
    error({K, N});
check_positive(_, N) ->
    N.
