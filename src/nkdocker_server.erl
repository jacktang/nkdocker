%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc NkDOCKER Management Server
-module(nkdocker_server).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start_link/1, start/1, stop/1, cmd/5, data/3, finish/2, create_spec/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, 
         handle_info/2]).
-export_type([cmd_opts/0]).

-include("nkdocker.hrl").

-type cmd_opts() :: 
    #{
        async => boolean(),
        force_new => boolean(),
        headers => [{binary(), binary()}],
        redirect => string(),           % Send to file
        timeout => pos_integer(),       % Reply and closes connection if reached
        % refresh => boolean(),           % Automatic refresh
        chunks => boolean()             % Send data in chunks
    }.


-define(TIMEOUT, 5000).

%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts a docker connection
-spec start_link(nkdocker:conn_opts()) ->
    {ok, pid()} | {error, term()}.

start_link(Opts) ->
    gen_server:start_link(?MODULE, [Opts], []).


%% @doc Starts a docker connection
-spec start(nkdocker:conn_opts()) ->
    {ok, pid()} | {error, term()}.

start(Opts) ->
    gen_server:start(?MODULE, [Opts], []).


%% @doc Stops a docker connection
-spec stop(pid()) ->
    ok.

stop(Pid) ->
    gen_server:cast(Pid, stop).


%% @doc Sends a message
%% Every connection has a timeout, so it will never block
-spec cmd(pid(), binary(), binary(), binary()|iolist()|map(), cmd_opts()) ->
    ok | {ok, term()|binary()} | {error, term()}.

cmd(Pid, Verb, Path, Body, Opts) ->
    % Path1 = <<"/v1.17", Path/binary>>,
    Timeout = max(maps:get(timeout, Opts, 5000), 5000),
    case nklib_util:call(Pid, {cmd, Verb, Path, Body, Opts}, Timeout) of
        {error, {exit, {{timeout, _}, _}}} -> {error, call_timeout};
        Other -> Other
    end.


%% @doc Sends a in-message data
-spec data(pid(), reference(), iolist()) ->
    ok | {error, term()}.

data(Pid, Ref, Data) ->
    nklib_util:call(Pid, {data, Ref, Data}).


%% @doc Finished an asynchronous command
-spec finish(pid(), reference()) ->
    ok | {error, term()}.

finish(Pid, Ref) ->
    nklib_util:call(Pid, {finish_async, Ref}).


%% @doc Generates creation options
-spec create_spec(pid(), nkdocker:create_opts()) ->
    {ok, map()} | {error, term()}.

create_spec(Pid, Opts) ->
    case nklib_util:call(Pid, get_vsn) of
        {ok, Vsn} -> nkdocker_opts:create_spec(Vsn, Opts);
        {error, Error} -> {error, Error}
    end.


% %% @private
% refresh_fun(NkPort) ->
%     lager:warning("Refreshing connection"),
%     case nkpacket_connection_lib:raw_send(NkPort, <<"\r\n">>) of
%         ok -> true;
%         _ -> false
%     end.


%% ===================================================================
%% gen_server
%% ===================================================================


-record(cmd, {
    from_pid :: pid(), 
    from_ref :: reference(),
    conn_pid :: pid(),
    conn_ref :: reference(),
    mode :: shared | exclusive | async | {redirect, file:io_device()},
    use_chunks :: boolean(),
    status = 0 :: integer(),
    ct :: json | stream | undefined, 
    chunks = [] :: [term()],
    stream_buff = <<>> :: binary(),
    user_mon :: reference()
}).

-record(state, {
    conn :: nkpacket:raw_connection(),
    conn_opts :: map(),
    host :: binary(),
    vsn :: binary(),
    cmds = [] :: [#cmd{}]
}).


%% @private 
-spec init(term()) ->
    {ok, #state{}} | {stop, term()}.

init([Opts]) ->
    process_flag(trap_exit, true),      %% Allow calls to terminate/2
    case nkdocker_util:get_conn_info(Opts) of
        {ok, #{ip:=Ip, port:=Port, proto:=Proto}=Opts2} ->
            Conn = {nkdocker_protocol, Proto, Ip, Port},
            TLSKeys = nkpacket_util:tls_keys(),
            TLSOpts = maps:with(TLSKeys, Opts2),
            ConnOpts = TLSOpts#{
                class => {nkdocker, self()},
                monitor => self(), 
                user => {notify, self()}, 
                idle_timeout => ?TIMEOUT
            },
            Host = list_to_binary([
                nklib_util:to_host(Ip),
                <<":">>,
                nklib_util:to_binary(Port)
            ]),
            lager:info("NkDOCKER connecting to ~s, (~p)", [Host, ConnOpts]),
            case nkpacket:connect(Conn, ConnOpts) of
                {ok, _Pid} ->
                    State = #state{
                        conn = Conn,
                        conn_opts = ConnOpts,
                        host = Host,
                        cmds = []
                    },
                    case get_version(State) of
                        {ok, Vsn} when Vsn >= <<"1.17">> ->
                            {ok, State#state{vsn=Vsn}};
                        {ok, Vsn} ->
                            {stop, {invalid_docker_version, Vsn}};
                        {error, Error} ->
                            {stop, Error}
                    end;
                {error, Error} ->
                    {stop, {connection_error, Error}}
            end;
        {error, Error} ->
            {stop, Error}
    end.


%% @private
-spec handle_call(term(), {pid(), reference()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} | {stop, term(), term(), #state{}}.

handle_call({cmd, Verb, Path, Body, Opts}, From, State) ->
    try
        Opts1 = case Opts of
            #{redirect:=File} ->
                case file:open(nklib_util:to_list(File), [write, raw]) of
                    {ok, Port} -> 
                        Opts#{redirect:=Port};
                    {error, FileError} -> 
                        throw({could_not_open, File, FileError})
                end;
            _ ->
                Opts
        end,
        Async = maps:get(async, Opts, false),
        case send(Verb, Path, Body, Opts1, From, State) of
            {ok, State1} when Async ->
                {reply, {async, element(2, From)}, State1};
            {ok, State1} ->
                {noreply, State1};
            {error, Error} ->
                {stop, normal, {error, Error}, State}
        end
    catch
        throw:Throw -> {reply, {error, Throw}, State}
    end;

handle_call({data, Ref, Data}, _From, #state{cmds=Cmds}=State) ->
    case lists:keyfind(Ref, #cmd.from_ref, Cmds) of
        #cmd{mode=async, conn_pid=ConnPid}=Cmd ->
            case catch nkpacket_connection:send(ConnPid, {data, Ref, Data}) of
                ok -> 
                    {reply, ok, State};
                Error ->
                    State1 = send_stop(Cmd, {error, send_error}, State),
                    {reply, {error, Error}, State1}
            end;
        false ->
            {reply, {error, unknown_ref}, State}
    end;

handle_call({finish_async, Ref}, _, #state{cmds=Cmds}=State) ->
    case lists:keyfind(Ref, #cmd.from_ref, Cmds) of
        #cmd{mode=async}=Cmd ->
            State1 = send_stop(Cmd, {ok, user_stop}, State),
            {reply, ok, State1};
        _ ->
            {reply, {error, unknown_ref}, State}
    end;

handle_call(get_vsn, _From, #state{vsn=Vsn}=State) ->
    {reply, {ok, Vsn}, State};

handle_call(get_state, _From, State) ->
    {reply, State, State};

handle_call(Msg, _From, State) -> 
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, normal, #state{}}.

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({nkdocker, Ref, {head, Status, Headers}}, #state{cmds=Cmds}=State) ->
    lager:debug("Head: ~p, ~p", [Status, Headers]),
    case lists:keyfind(Ref, #cmd.from_ref, Cmds) of
        #cmd{}=Cmd  ->
            CT = case nklib_util:get_value(<<"content-type">>, Headers) of
                <<"application/json">> -> json;
                <<"application/vnd.docker.raw-stream">> -> stream;
                _ -> undefined
            end,
            Cmd1 = Cmd#cmd{status=Status, ct=CT},
            Cmds1 = lists:keystore(Ref, #cmd.from_ref, Cmds, Cmd1),
            {noreply, State#state{cmds=Cmds1}};
        false ->
            lager:warning("Received unexpected head!"),
            {noreply, State}
    end;

handle_info({nkdocker, Ref, {chunk, Data}}, #state{cmds=Cmds}=State) ->
    % lager:debug("Chunk: ~p", [Data]),
    case lists:keyfind(Ref, #cmd.from_ref, Cmds) of
        #cmd{mode={redirect, _}}=Cmd ->
            {noreply, parse_chunk(Data, Cmd, State)};
        #cmd{ct=stream}=Cmd ->
            case parse_stream(Data, Cmd) of
                {ok, Stream, Cmd1} ->
                    Cmds1 = lists:keystore(Ref, #cmd.from_ref, Cmds, Cmd1),
                    {noreply, parse_chunk(Stream, Cmd1, State#state{cmds=Cmds1})};
                {more, Cmd1} ->
                    Cmds1 = lists:keystore(Ref, #cmd.from_ref, Cmds, Cmd1),
                    {noreply, State#state{cmds=Cmds1}}
            end;
        #cmd{}=Cmd ->
            {noreply, parse_chunk(Data, Cmd, State)};
    false ->
        lager:warning("Received unexpected chunk!"),
        {noreply, State}
    end;

handle_info({nkdocker, Ref, {body, Body}}, #state{cmds=Cmds}=State) ->
    lager:debug("Body: ~p", [Body]),
    case lists:keyfind(Ref, #cmd.from_ref, Cmds) of
        #cmd{status=Status}=Cmd when Status>=200, Status<300 ->
            {noreply, parse_body(Body, Cmd, State)};
        #cmd{status=Status}=Cmd ->
            {noreply, send_stop(Cmd, {error, {get_error(Status), Body}}, State)};
        false ->
            lager:warning("Received unexpected body!"),
            {noreply, State}
    end;

handle_info({'DOWN', MRef, process, _MPid, _Reason}, #state{cmds=Cmds}=State) ->
    State1 = case lists:keyfind(MRef, #cmd.conn_ref, Cmds) of
        #cmd{mode=async}=Cmd ->
            send_stop(Cmd, {error, connection_failed}, State);
        #cmd{mode={redirect, _}}=Cmd ->
            send_stop(Cmd, {error, connection_failed}, State);
        #cmd{ct=stream}=Cmd ->
            parse_body(<<>>, Cmd, State);
        #cmd{}=Cmd ->
            send_stop(Cmd, {error, connection_failed}, State);
        false ->
            case lists:keyfind(MRef, #cmd.user_mon, Cmds) of
                #cmd{}=Cmd ->
                    send_stop(Cmd, skip, State);
                false ->
                    State
            end
    end,
    {noreply, State1};

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(_Reason, _State) ->  
    ok.



%% ===================================================================
%% Private
%% ===================================================================

%% @private
-spec get_version(#state{}) ->
    {ok, binary()} | {stop, term()}.

get_version(#state{conn=Conn, conn_opts=ConnOpts}=State) ->
    Ref = make_ref(),
    Msg = {http, Ref, <<"GET">>, <<"/version">>, headers1(State), <<>>},
    case nkpacket:send(Conn, Msg, ConnOpts) of
        {ok, _} ->
            case
                receive 
                    {nkdocker, Ref, {head, 200, _}} ->
                        receive
                            {nkdocker, Ref, {body, Data}} -> 
                                nklib_json:decode(Data)
                        after
                            5000 -> timeout
                        end
                after
                    5000 -> timeout
                end
            of
                #{<<"ApiVersion">>:=ApiVersion} ->
                    {ok, ApiVersion};
                timeout ->
                    {error, connect_timeout};
                Other ->
                    {error, {invalid_return_from_get_version, Other}}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec send(binary(), binary(), binary(), cmd_opts(), {pid(), reference()}, 
           #state{}) ->
    {ok, #state{}} | {error, term()}.

send(Method, Path, Body, Opts, From, State) ->
    #state{conn=Conn, conn_opts=ConnOpts, cmds=Cmds} = State,
    Mode = case Opts of
        #{async:=true} -> async;
        #{force_new:=true} -> exclusive;
        #{redirect:=Port} -> {redirect, Port};
        _ -> shared
    end,
    {ConnOpts1, Hds1} = case Mode of
        shared -> 
            {
                ConnOpts,
                headers1(State)
            };
        _ -> 
            {
                ConnOpts#{
                    class => {nkdocker, self(), exclusive},
                    idle_timeout => maps:get(timeout, Opts, ?TIMEOUT),
                    force_new => true
                },
                headers2(State)
            }
    end,
    % ConnOpts2 = case Opts of
    %     #{refresh:=true} -> 
    %         ConnOpts1#{refresh_fun=>fun ?MODULE:refresh_fun/1};
    %     _ -> 
    %         ConnOpts1
    % end,
    ConnOpts2 = ConnOpts1,
    Hds2 = case Opts of
        #{headers:=Headers} -> 
            Hds1 ++ Headers;
        _ -> 
            Hds1
    end,
    {FromPid, FromRef} = From,
    Msg = {http, FromRef, Method, Path, Hds2, Body},
    lager:debug("NkDOCKER SEND: ~p ~p", [Msg, ConnOpts2]),
    case nkpacket:send(Conn, Msg, ConnOpts2) of
        {ok, ConnPid} ->
            Cmd1 = #cmd{
                from_pid = FromPid,
                from_ref = FromRef, 
                conn_pid = ConnPid,
                conn_ref = erlang:monitor(process, ConnPid), 
                mode = Mode,
                use_chunks = maps:get(chunks, Opts, false)
            },
            Cmd2 = case Mode of
                async ->
                    UserMon = erlang:monitor(process, element(1, From)),
                    Cmd1#cmd{user_mon=UserMon};
                _ ->
                    Cmd1
            end,
            {ok, State#state{cmds=[Cmd2|Cmds]}};
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec parse_chunk(binary(), #cmd{}, #state{}) ->
    #state{}.

parse_chunk(Data, #cmd{mode={redirect, Port}}=Cmd, State) ->
    case file:write(Port, Data) of
        ok ->
            State;
        {error, Error} -> 
            send_stop(Cmd, {error, {file_error, Error}}, State)
    end;

parse_chunk(Data, #cmd{mode=async, use_chunks=true}=Cmd, State) ->
    #cmd{from_ref=Ref, from_pid=Pid} = Cmd,
    Pid ! {nkdocker, Ref, {data, decode(Data, Cmd)}},
    State;

parse_chunk(Data, Cmd, #state{cmds=Cmds}=State) ->
    #cmd{chunks=Chunks, use_chunks=UseChunks, from_ref=Ref} = Cmd,
    Chunk = case UseChunks of
        true -> decode(Data, Cmd);
        false -> Data
    end,
    Cmd1 = Cmd#cmd{chunks=[Chunk|Chunks]},
    Cmds1 = lists:keystore(Ref, #cmd.from_ref, Cmds, Cmd1),
    State#state{cmds=Cmds1}.


%% @private
-spec parse_body(binary(), #cmd{}, #state{}) ->
    #state{}.

parse_body(Body, #cmd{mode={redirect, Port}}=Cmd, State) ->
    case file:write(Port, Body) of
        ok ->
            send_stop(Cmd, ok, State);
        {error, Error} -> 
            send_stop(Cmd, {error, {file_error, Error}}, State)
    end;

parse_body(Body, #cmd{chunks=Chunks, use_chunks=UseChunks}=Cmd, State) ->
    Reply = case Chunks of
        [] when Body == <<>> -> 
            {ok, <<>>};
        [] ->
            {ok, decode(Body, Cmd)};
        _ when Body == <<>>, UseChunks == false ->
            BigBody = list_to_binary(lists:reverse(Chunks)),
            {ok, decode(BigBody, Cmd)};
        _ when Body == <<>>, UseChunks == true ->
            {ok, lists:reverse(Chunks)};
        _ ->
            {ok, {invalid_chunked, Chunks, Body}}
    end,
    send_stop(Cmd, Reply, State).


%% @private
-spec parse_stream(binary(), #cmd{}) ->
    {ok, binary(), #cmd{}} | {more, #cmd{}}.

parse_stream(Data, #cmd{stream_buff=Buff}=Cmd) ->
    Data1 = << Buff/binary, Data/binary>>,
    case Data1 of
        _ when byte_size(Data1) < 8 ->
            {more, Cmd#cmd{stream_buff=Data1}};
        <<T, 0, 0, 0, Size:32, Msg/binary>> when T==0; T==1; T==2 ->
            D = case T of 0 -> <<"0:">>; 1 -> <<"1:">>; 2 -> <<"2:">> end,
            case byte_size(Msg) of
                Size -> 
                    {ok, <<D/binary, Msg/binary>>, Cmd#cmd{stream_buff= <<>>}};
                BinSize when BinSize < Size -> 
                    {more, Cmd#cmd{stream_buff=Data1}};
                _ -> 
                    {Msg1, Rest} = erlang:split_binary(Msg, Size),
                    {ok, <<D/binary, Msg1/binary>>, Cmd#cmd{stream_buff=Rest}}
            end;
        _ ->
            {ok, Data1, Cmd#cmd{stream_buff= <<>>}}
    end.


%% @private
-spec send_stop(#cmd{}, term(), #state{}) ->
    #state{}.

send_stop(Cmd, Reply, #state{cmds=Cmds}=State) ->
    #cmd{
        from_pid = Pid, 
        from_ref = Ref,
        conn_pid = ConnPid, 
        conn_ref = ConnRef,
        mode = Mode,
        user_mon = UserMon
    } = Cmd,
    case Mode of  
        async ->
            erlang:demonitor(ConnRef),
            erlang:demonitor(UserMon),
            nkpacket_connection:stop(ConnPid, normal);
        shared -> 
            ok;
        exclusive -> 
            erlang:demonitor(ConnRef),
            nkpacket_connection:stop(ConnPid, normal);
        {redirect, Port} ->
            file:close(Port),
            erlang:demonitor(ConnRef),
            nkpacket_connection:stop(ConnPid, normal)
    end,
    case Reply of
        skip ->
            ok;
        _ when Mode==async ->
            Pid ! {nkdocker, Ref, Reply};
        _ ->
            gen_server:reply({Pid, Ref}, Reply)
    end,
    Cmds1 = lists:keydelete(Ref, #cmd.from_ref, Cmds),
    State#state{cmds=Cmds1}.


%% @private
get_error(Status) ->
    case Status of
        304 -> not_modified;
        400 -> bad_parameter;
        401 -> unauthorized;
        404 -> not_found;
        406 -> not_running;
        409 -> conflict;
        500 -> server_error;
        _ -> Status
    end.


decode(Data, #cmd{ct=json}) ->
    case nklib_json:decode(Data) of
        {error, _} -> {invalid_json, Data};
        Msg -> Msg
    end;

decode(Data, _) ->
    Data.


%% @private
headers1(State) ->
    [
        {<<"Connection">>, <<"keep-alive">>} |
        headers2(State)
    ].


%% @private
headers2(#state{host=Host}) ->
    [
        {<<"Host">>, Host},
        {<<"User-Agent">>, <<"nkdocker/develop">>},
        {<<"Accept">>, <<"*/*">>}
    ].


