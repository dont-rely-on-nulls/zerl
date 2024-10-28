#!/usr/bin/env escript
%%! -sname cards -setcookie cards_cookie

main(_) ->
  register('dealer', self()),
  wait_for_customer().

wait_for_customer() ->
  receive
    {hello, Pid} -> Pid ! ok, has_customer(Pid);
    _ -> io:format(<<"Got nonsense, giving up.\n">>), halt(1)
  end.

with_random_key(V) -> {rand:uniform(), V}.
extract({_, V}) -> V.

has_customer(Pid) ->
  receive
    {say, _} ->
      Pid ! {say, "Well met!"},
      has_customer(Pid);
    {integer, N} ->
      try N bsr 1 of
        Half_N -> Pid ! {halved, Half_N}
      catch
        _ -> Pid ! {error, invalid_message}
      end,
      has_customer(Pid);
    {shuffle, Cards} ->
      Randomized = lists:sort(lists:map(fun with_random_key/1, Cards)),
      Pid ! {shuffled, lists:map(fun extract/1, Randomized)},
      has_customer(Pid);
    bye -> Pid ! ok, halt(0);
    _ -> Pid ! {error, unknown_message}, has_customer(Pid)
  end.
