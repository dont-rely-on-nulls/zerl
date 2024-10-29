#!/usr/bin/env escript
%%! -sname hello -setcookie hello_cookie

main(_) ->
  register('echo', self()),
  echo().

echo() ->
  receive
    {Pid, Message} -> Pid ! {ok, Message}, echo();
    _ -> halt()
  end.
