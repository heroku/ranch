%% Copyright (c) 2011-2014, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(ranch_acceptor).

-export([start_link/6]).
-export([loop/7]).

-spec start_link(inet:socket(), module(), reference()| atom(),
                 atom(), integer(), pid())
	-> {ok, pid()}.
start_link(LSocket, Transport, Ref, Protocol, AckTimeout, ConnsSup) ->
	Opts = ranch_server:get_protocol_options(Ref),
	Pid = spawn_link(?MODULE, loop,
                     [LSocket, Transport, Ref, Protocol,
                      Opts, AckTimeout, ConnsSup]),
	{ok, Pid}.

-spec loop(inet:socket(), module(), reference()| atom(), atom(),
           term(), integer(), pid()) ->
                  no_return().
loop(LSocket, Transport, Ref, Protocol, Opts, AckTimeout, ConnsSup) ->
	_ = case Transport:accept(LSocket, infinity) of
            {ok, Socket} ->
                case Protocol:start_link(Ref, Socket, Transport, Opts) of
                    {ok, Pid} ->
                        case Transport:controlling_process(Socket, Pid) of
                            M when M =:= ok orelse M =:= {error, not_owner} ->
                                Pid ! {shoot, Ref, Transport, Socket, AckTimeout},
                                case application:get_env(ranch, {Ref, max_conns}) of
                                    {ok, infinity} ->
                                        ranch_conns_sup:start_protocol_async(ConnsSup, Pid);
                                    _ ->
                                        ranch_conns_sup:start_protocol(ConnsSup, Pid)
                                end;
                            {error, _} ->
                                Transport:close(Socket),
                                exit(Pid, kill)
                        end;
                    Ret ->
                        error_logger:error_msg(
                          "Ranch listener ~p connection process start failure; "
                          "~p:start_link/4 returned: ~999999p~n",
                          [Ref, Protocol, Ret]),
                        Transport:close(Socket)
                end;
            %% Reduce the accept rate if we run out of file descriptors.
            %% We can't accept anymore anyway, so we might as well wait
            %% a little for the situation to resolve itself.
            {error, emfile} ->
                receive after 100 -> ok end;
            %% We want to crash if the listening socket got closed.
            {error, Reason} when Reason =/= closed ->
                ok
        end,
	flush(),
	?MODULE:loop(LSocket, Transport, Ref, Protocol, Opts, AckTimeout, ConnsSup).

flush() ->
	receive
        %% ignore replies from ranch_conns_sup when we're sending async
        Msg when is_pid(Msg) ->
            flush();
        Msg ->
            error_logger:error_msg(
              "Ranch acceptor received unexpected message: ~p~n",
              [Msg]),
            flush()
	after 20 ->
            ok
	end.
