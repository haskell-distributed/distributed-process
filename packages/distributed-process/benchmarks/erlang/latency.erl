-module(latency).

-export([server/0, client/2, start_server/0, start_client/2]).

forever(What) ->
  What(),
  forever(What).

replicate(0, _) ->
  ok;
replicate(N, What) ->
  What(),
  replicate(N - 1, What).

server() ->
  forever(fun () -> 
            receive 
              Them -> Them ! pong 
            end 
          end). 

client(N, Them) ->
  replicate(N, fun() ->
                 {pingServer, Them} ! self(),
                 receive 
                   pong -> ok
                 end
               end),
  io:format("Did ~B pings", [N]).
 
start_server() ->
  register(pingServer, spawn(latency, server, [])).

start_client(N, Them) ->
  client(N, Them).
