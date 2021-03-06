%  @copyright 2007-2010 Konrad-Zuse-Zentrum fuer Informationstechnik Berlin

%   Licensed under the Apache License, Version 2.0 (the "License");
%   you may not use this file except in compliance with the License.
%   You may obtain a copy of the License at
%
%       http://www.apache.org/licenses/LICENSE-2.0
%
%   Unless required by applicable law or agreed to in writing, software
%   distributed under the License is distributed on an "AS IS" BASIS,
%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%   See the License for the specific language governing permissions and
%   limitations under the License.

%%% @author Thorsten Schuett <schuett@zib.de>
%%% @doc    routing table process
%%% @end
%% @version $Id: rt_loop.erl 944 2010-07-29 16:02:38Z kruber@zib.de $
-module(rt_loop).
-author('schuett@zib.de').
-vsn('$Id: rt_loop.erl 944 2010-07-29 16:02:38Z kruber@zib.de $').

-behaviour(gen_component).

-include("scalaris.hrl").

% for routing table implementation
-export([start_link/1]).
-export([init/1, on/2, get_base_interval/0, check_config/0,
         get_id/1, get_pred/1, get_succ/1, get_rt/1, set_rt/2,
         initialize/3, update_state/3]).

-ifdef(with_export_type_support).
-export_type([state_init/0]).
-endif.

% state of the routing table loop
%% userdevguide-begin rt_loop:state
-opaque(state_init() :: {Id           :: ?RT:key(),
                         Pred         :: node:node_type(),
                         Succ         :: node:node_type(),
                         RTState      :: ?RT:rt(),
                         TriggerState :: trigger:state()}).
-type(state_uninit() :: {uninit, TriggerState :: trigger:state()}).
-type(state() :: state_init() | state_uninit()).
%% userdevguide-end rt_loop:state

% accepted messages of rt_loop processes
-type(message() ::
    {init_rt, Id::?RT:key(), Pred::node:node_type(), Succ::node:node_type()} |
    {update, Id::?RT:key(), Pred::node:node_type(), Succ::node:node_type()} |
    {stabilize} |
    {crash, DeadPid::comm:mypid()} |
    ?RT:custom_message()).

%% @doc Sends an initialization message to the node's routing table.
-spec initialize(Id::?RT:key(), Pred::node:node_type(), Succ::node:node_type()) -> ok.
initialize(Id, Pred, Succ) ->
    Pid = process_dictionary:get_group_member(routing_table),
    comm:send_local(Pid, {init_rt, Id, Pred, Succ}).

%% @doc Notifies the node's routing table of a changed node ID, predecessor
%%      and/or successor.
-spec update_state(Id::?RT:key(), Pred::node:node_type(), Succ::node:node_type()) -> ok.
update_state(Id, Pred, Succ) ->
    comm:send_local(process_dictionary:get_group_member(routing_table),
                    {update_rt, Id, Pred, Succ}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Startup
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Starts the routing tabe maintenance process, registers it with the
%%      process dictionary and returns its pid for use by a supervisor.
-spec start_link(instanceid()) -> {ok, pid()}.
start_link(InstanceId) ->
    Trigger = config:read(routingtable_trigger),
    gen_component:start_link(?MODULE, Trigger, [{register, InstanceId, routing_table}]).

%% @doc Initialises the module with an empty state.
-spec init(module()) -> {uninit, trigger:state()}.
init(Trigger) ->
    % Note: no need to call dht_node:register_for_node_change(self()) since we
    % get notified of a new node ID via the update_state/3 method that is
    % called in dht_node's rm_update_neighbors handler
    log:log(info,"[ RT ~p ] starting routingtable", [comm:this()]),
    TriggerState = trigger:init(Trigger, ?MODULE),
    {uninit, TriggerState}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Private Code
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc message handler
-spec on(message(), state()) -> state() | unknown_event.

on({init_rt, Id, Pred, Succ}, {uninit, TriggerState}) ->
    TriggerState2 = trigger:next(TriggerState),
    {Id, Pred, Succ, ?RT:empty(Succ), TriggerState2};

on(Message, {uninit, TriggerState}) ->
    comm:send_local(self() , Message),
    {uninit, TriggerState};

% re-initialize routing table
on({init_rt, NewId, NewPred, NewSucc}, {_, OldPred, OldSucc, OldRT, TriggerState}) ->
    NewRT = ?RT:empty(NewSucc),
    ?RT:check(OldRT, NewRT, NewId, OldPred, NewPred, OldSucc, NewSucc),
    new_state(NewId, NewPred, NewSucc, NewRT, TriggerState);

%% userdevguide-begin rt_loop:update_rt
% update routing table with changed ID, pred and/or succ
on({update_rt, NewId, NewPred, NewSucc}, {OldId, OldPred, OldSucc, OldRT, TriggerState}) ->
    case ?RT:update(NewId, NewPred, NewSucc, OldRT, OldId, OldPred, OldSucc) of
        {trigger_rebuild, NewRT} ->
            % trigger immediate rebuild
            NewTriggerState = trigger:now(TriggerState),
            ?RT:check(OldRT, NewRT, NewId, OldPred, NewPred, OldSucc, NewSucc),
            new_state(NewId, NewPred, NewSucc, NewRT, NewTriggerState);
        {ok, NewRT} ->
            ?RT:check(OldRT, NewRT, NewId, OldPred, NewPred, OldSucc, NewSucc),
            new_state(NewId, NewPred, NewSucc, NewRT, TriggerState)
    end;
%% userdevguide-end rt_loop:update_rt

%% userdevguide-begin rt_loop:trigger
on({trigger}, {Id, Pred, Succ, RTState, TriggerState}) ->
    % start periodic stabilization
    % log:log(info, "[ RT ] stabilize~n"),
    NewRTState = ?RT:init_stabilize(Id, Succ, RTState),
    ?RT:check(RTState, NewRTState, Id, Pred, Succ),
    % trigger next stabilization
    NewTriggerState = trigger:next(TriggerState),
    new_state(Id, Pred, Succ, NewRTState, NewTriggerState);
%% userdevguide-end rt_loop:trigger

% failure detector reported dead node
on({crash, DeadPid}, {Id, Pred, Succ, OldRT, TriggerState}) ->
    NewRT = ?RT:filter_dead_node(OldRT, DeadPid),
    ?RT:check(OldRT, NewRT, Id, Pred, Succ, false),
    new_state(Id, Pred, Succ, NewRT, TriggerState);

% debug_info for web interface
on({'$gen_cast', {debug_info, Requestor}}, {_Id, _Pred, _Succ, RTState, _TriggerState} = State) ->
    KeyValueList =
        [{"rt_size", ?RT:get_size(RTState)},
         {"rt (index, node):", ""} | ?RT:dump(RTState)],
    comm:send_local(Requestor, {debug_info_response, KeyValueList}),
    State;

on({dump, Pid}, {_Id, _Pred, _Succ, RTState, _TriggerState} = State) ->
    comm:send_local(Pid, {dump_response, RTState}),
    State;

% unknown message
on(Message, State) ->
    ?RT:handle_custom_message(Message, State).

% handling rt_loop's (opaque) state - these handlers should at least be used
% outside this module:

-spec new_state(Id::?RT:key(), Pred::node:node_type(), Succ::node:node_type(),
                 RTState::?RT:rt(), TriggerState::trigger:state()) -> state_init().
new_state(Id, Pred, Succ, RTState, TriggerState) ->
    {Id, Pred, Succ, RTState, TriggerState}.

-spec get_id(State::state_init()) -> ?RT:key().
get_id(State) -> element(1, State).

-spec get_pred(State::state_init()) -> node:node_type().
get_pred(State) -> element(2, State).

-spec get_succ(State::state_init()) -> node:node_type().
get_succ(State) -> element(3, State).

-spec get_rt(State::state_init()) -> ?RT:rt().
get_rt(State) -> element(4, State).

-spec set_rt(State::state_init(), RT::?RT:rt()) -> NewState::state_init().
set_rt(State, RT) -> setelement(4, State, RT).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec get_base_interval() -> pos_integer().
get_base_interval() ->
    config:read(pointer_base_stabilization_interval).

%% @doc Checks whether config parameters of the rt_loop process exist and are
%%      valid.
-spec check_config() -> boolean().
check_config() ->
    config:is_integer(pointer_base_stabilization_interval) and
        config:is_greater_than_equal(pointer_base_stabilization_interval, 1000).
