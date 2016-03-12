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

%% @private NkDOCKER main supervisor
-module(nkdocker_sup).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(supervisor).

-export([start_events/2, init/1, start_link/0]).

% -include("nkmedia.hrl").

start_events(Id, Opts) ->
	Spec = {
        {events, Id},
        {nkdocker_events, start_link, [Id, Opts]},
        permanent,
        5000,
        worker,
        [nkdocker_events]
    },
	case supervisor:start_child(?MODULE, Spec) of
        {ok, Pid} -> 
            {ok, Pid};
        {error, already_present} ->
            ok = supervisor:delete_child(?MODULE, {events, Id}),
            start_events(Id, Opts);
        {error, {already_started, Pid}} -> 
            {ok, Pid};
        {error, Error} -> 
            {error, Error}
    end.


%% @private
start_link() ->
    Childs = [],
    supervisor:start_link({local, ?MODULE}, ?MODULE, {{one_for_one, 10, 60}, Childs}).


%% @private
init(ChildSpecs) ->
    {ok, ChildSpecs}.




