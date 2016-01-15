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
-export([loop/8]).

-spec start_link(inet:socket(), module(), reference()| atom(),
                 atom(), integer(), pid())
	-> {ok, pid()}.
start_link(PortOpts, Transport, Ref, Protocol, AckTimeout, ConnsSup) ->
	Opts = ranch_server:get_protocol_options(Ref),
    {ok, LSocket} = Transport:listen([{raw, 1, 15, <<1:32/native>>}|PortOpts]),
	Pid = spawn_link(?MODULE, loop,
                     [LSocket, Transport, Ref, Protocol,
                      Opts, AckTimeout, ConnsSup, 0]),
	{ok, Pid}.

-spec loop(inet:socket(), module(), reference()| atom(), atom(),
           term(), integer(), pid(), integer) ->
                  no_return().
loop(LSocket, Transport, Ref, Protocol, Opts, AckTimeout, ConnsSup, Flush) ->
    prim_inet:async_accept(LSocket, -1),
    Socks =
    receive
        {inet_async, _ListSock, _Ref, {ok, InitSocket}} ->
            get_socks(LSocket, [InitSocket])
    end,
    [begin
        inet_db:register_socket(Socket, inet_tcp),
        {ok, Pid} = Protocol:start_link(Ref, Socket, Transport, Opts),
        Transport:controlling_process(Socket, Pid)
     end || Socket <- Socks],
	case Flush of
        1000 ->
            %% flush(),
	        ?MODULE:loop(LSocket, Transport, Ref, Protocol, Opts, AckTimeout, ConnsSup, 0);
        _ ->
	        ?MODULE:loop(LSocket, Transport, Ref, Protocol, Opts, AckTimeout, ConnsSup, Flush + 1)
        end.

get_socks(LSocket, Acc) ->
    prim_inet:async_accept(LSocket, -1),
    receive
        {inet_async, _ListSock, _Ref, {ok, InitSocket}} ->
            get_socks(LSocket, [InitSocket|Acc])
    after 0 ->
        Acc
    end.

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
	after 0 ->
            ok
	end.
