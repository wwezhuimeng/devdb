% @copyright 2007-2010 Konrad-Zuse-Zentrum fuer Informationstechnik Berlin,

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

%% @author Thorsten Schuett <schuett@zib.de>
%% @doc Process dictionary.
%%
%%      This module provides a mechanism to implement process
%%      groups. Within a process group, the names of processes have to
%%      be unique, but the same name can be used in different
%%      groups. The motivation for this module was to run several scalaris
%%      nodes in one erlang vm. But for the processes forming a scalaris
%%      node being able to talk to each other, they have to now their
%%      names (dht_node, config, etc.). This module allows the processes
%%      to keep their names.
%% 
%%      When a new process group is created, a unique "instance_id" is
%%      created, which has to be shared by all nodes in this
%%      group.
%% 
%%      {@link register_process/3} registers the name of a process in
%%      his group and stores the instance_id in the calling processes'
%%      environment using {@link erlang:put/2}.
%% 
%%      {@link lookup_process/2} will lookup in the process group for a
%%      process with the given name.
%% @end
%% @version $Id: process_dictionary.erl 940 2010-07-28 16:01:02Z kruber@zib.de $
-module(process_dictionary).
-author('schuett@zib.de').
-vsn('$Id: process_dictionary.erl 940 2010-07-28 16:01:02Z kruber@zib.de $').

-behaviour(gen_component).

-include("scalaris.hrl").

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,on/2,
         register_process/3,
         lookup_process/2,
         lookup_process/1,
         find_dht_node/0,
         find_all_dht_nodes/0,
         find_all_processes/1,
         find_group/1,
         find_all_groups/1,

         get_groups/0,
         get_processes_in_group/1,
         get_group_member/1,
         get_info/2,

         %for fprof
         get_all_pids/0]).

-type(name() :: atom()).

-type(message() ::
    {register_process, instanceid(), name(), pid()} |
    {drop_state} |
    {'EXIT', pid(), Reason::any()}).

%%====================================================================
%% public functions
%%====================================================================

%% @doc register a process with InstanceId and Name and stores the
%%      process group info with put/2
-spec register_process(instanceid(), name(), pid()) -> ok.
register_process(InstanceId, Name, Pid) ->
    erlang:put(instance_id, InstanceId),
    erlang:put(instance_name, Name),
    comm:send_local(get_pid(), {register_process, InstanceId, Name, Pid}),
    receive {process_registered} -> ok end.

%% @doc looks up a process with InstanceId and Name in the dictionary
-spec lookup_process(instanceid(), name()) -> pid() | failed.
lookup_process(InstanceId, Name) ->
%%     [Counter] = ets:lookup(call_counter, lookup_process_by_group),
%%     ets:insert(call_counter, {lookup_process_by_group, Counter + 1}),
    case ets:lookup(?MODULE, {InstanceId, Name}) of
        [{{InstanceId, Name}, Value}] ->
            Value;
        [] ->
            %log:log(error, "[ PD ] lookup_process failed in Pid ~p: InstanceID:  "
            %        "~p  For: ~p StacK: ~p~n",[self(), InstanceId, Name,
            %                                   util:get_stacktrace()]),
            failed
    end.
    %gen_server:call(?MODULE, {lookup_process, InstanceId, Name}, 20000).

%% @doc find the process group and name of a process by pid
-spec lookup_process(pid()) -> {instanceid(), name()} | failed.
lookup_process(Pid) ->
%%     [Counter] = ets:lookup(call_counter, lookup_process_by_name),
%%     ets:insert(call_counter, {lookup_process_by_name, Counter + 1}),
    case ets:match(?MODULE, {'$1',Pid}) of
        [[{Group, Name}]] ->
            {Group, Name};
        [] ->
            failed
    end.

%% @doc tries to find a dht_node process
-spec find_dht_node() -> {ok, pid()} | failed.
find_dht_node() ->
    find_process(dht_node).

%% @doc tries to find all dht_node processes
-spec find_all_dht_nodes() -> [pid()].
find_all_dht_nodes() ->
    find_all_processes(dht_node).

-spec find_process(name()) -> {ok, pid()} | failed.
find_process(Name) ->
    case ets:match(?MODULE, {{'_', Name}, '$1'}) of
         [[Value] | _] ->
             {ok, Value};
         [] ->
             failed
         end.

-spec find_all_processes(name()) -> [pid()].
find_all_processes(Name) ->
    %ct:pal("ets:info: ~p~n",[ets:info(?MODULE)]),
    Result = ets:match(?MODULE, {{'_', Name}, '$1'}),
    lists:flatten(Result).

%% @doc tries to find a process group with a specific process inside
-spec find_group(ProcessName::name()) -> instanceid() | failed.
find_group(ProcessName) ->
    case ets:match(?MODULE, {{'$1', ProcessName}, '_'}) of
        [[Value] | _] ->
            Value;
        [] ->
            failed
    end.

-spec find_all_groups(ProcessName::name()) -> [instanceid(),...] | failed.
find_all_groups(ProcessName) ->
    case ets:match(?MODULE, {{'$1', ProcessName}, '_'}) of
        [] ->
            failed;
        List ->
            lists:append(List)
    end.

%% @doc find groups for web interface
-spec get_groups() -> {array, [{struct, [{id | text, instanceid()} | {leaf, false}]}]}.
get_groups() ->
    AllGroups = find_all_groups(ets:tab2list(?MODULE), gb_sets:new()),
    GroupsAsJson = {array, lists:foldl(fun(El, Rest) -> [{struct, [{id, El}, {text, El}, {leaf, false}]} | Rest] end, [], gb_sets:to_list(AllGroups))},
    GroupsAsJson.

%% @doc find processes in a group (for web interface)
%% @spec get_processes_in_group(term()) -> term()
-spec get_processes_in_group(instanceid()) -> {array, [{struct, [{id | text, nonempty_string()} | {leaf, true}]}]}.
get_processes_in_group(Group) ->
    AllProcesses = find_processes_in_group(ets:tab2list(?MODULE), gb_sets:new(), Group),
    ProcessesAsJson = {array, lists:foldr(fun(El, Rest) -> [{struct, [{id, toString(Group) ++ "." ++ toString(El)}, {text, toString(El)}, {leaf, true}]} | Rest] end, [], gb_sets:to_list(AllProcesses))},
    ProcessesAsJson.

%% @doc get info about process (for web interface)
-spec get_info(instanceid(), nonempty_string()) -> {struct, [{pairs, {array, {struct, [{key | value, nonempty_string()}]}}}]}.
get_info(InstanceId, Name) ->
    KVs =
        case lookup_process(InstanceId, list_to_atom(Name)) of
            failed ->
                [{"process", "unknown"}];
            Pid ->
                comm:send_local(Pid , {'$gen_cast', {debug_info, self()}}),
                {memory, Memory} = process_info(Pid, memory),
                {reductions, Reductions} = process_info(Pid, reductions),
                {message_queue_len, QueueLen} = process_info(Pid, message_queue_len),
                AddInfo =
                    receive
                        {debug_info_response, LocalKVs} -> LocalKVs
                    after 1000 ->
                        []
                    end,
                [{"memory", Memory}, {"reductions", Reductions}, {"message_queue_len", QueueLen} | AddInfo]
        end,
    JsonKVs = lists:map(fun({K, V}) -> {struct, [{key, K}, {value, toString(V)}]} end, KVs),
    {struct, [{pairs, {array, JsonKVs}}]}.

%% @doc Gets the Pid of the current process' group member with the given name.
-spec get_group_member(name()) -> pid() | failed.
get_group_member(Name) ->
    InstanceId = erlang:get(instance_id),
    if
        InstanceId =:= undefined ->
            log:log(error,"[ Node | ~w ] instance ID undefined: ~p", [self(),util:get_stacktrace()]);
        true ->
            ok
    end,
    Pid = process_dictionary:lookup_process(InstanceId, Name),
    case Pid of
        failed ->
            %log:log(error,"[ Node | ~w ] process ~w not found: ~p", [self(),Name,util:get_stacktrace()]),
            failed;
        _ -> Pid
    end.

-spec get_all_pids() -> [pid()].
get_all_pids() ->
    [X || [X]<- ets:match(?MODULE, {'_','$1'})].

%%====================================================================
%% API
%%====================================================================
%% @doc Starts the server
-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_component:start_link(?MODULE, [], [{register_native, process_dictionary}]).


%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @doc Initiates the server
%% @private
-spec init([]) -> null.
init(_Args) ->
    ets:new(?MODULE, [set, protected, named_table]),
     ets:new(call_counter, [set, public, named_table]),
%%     ets:insert(call_counter, {lookup_pointer, 0}),
%%    ets:insert(call_counter, {lookup_process_by_group, 0}),
%%     ets:insert(call_counter, {lookup_process_by_name, 0}),
%%    % required to gracefully eliminate dead, but registered processes from
    % the ets-table
    process_flag(trap_exit, true),
    State = null,
    State.

%% @doc Handling call messages
%% @private
-spec on(message(), null) -> null.
on({register_process, InstanceId, Name, Pid}, State) ->
    case ets:insert_new(?MODULE, {{InstanceId, Name}, Pid}) of
        true ->
            link(Pid);
        false ->
            OldPid = ets:lookup_element(?MODULE, {InstanceId, Name}, 2),
            unlink(OldPid),
            link(Pid),
            ets:insert_new(?MODULE, {{InstanceId, Name}, Pid})
    end,
    comm:send_local(Pid , {process_registered}),
    State;

on({drop_state}, State) ->
    % only for unit tests
    Links = ets:match(?MODULE, {'_', '$1'}),
    [unlink(Pid) || [Pid] <- Links],
    ets:delete_all_objects(?MODULE),
    State;

on({'EXIT', FromPid, _Reason}, State) ->
    Processes = ets:match(?MODULE, {'$1', FromPid}),
    [ets:delete(?MODULE, {InstanceId, Name}) || [{InstanceId, Name}] <- Processes],
    State.

-spec find_all_groups([{{instanceid(), name()}, pid()}], gb_set()) -> gb_set().
find_all_groups([], Set) ->
    Set;
find_all_groups([{{InstanceId, _}, _} | Rest], Set) ->
    find_all_groups(Rest, gb_sets:add_element(InstanceId, Set)).

-spec find_processes_in_group([{{instanceid(), name()}, pid()}], gb_set(), instanceid()) -> gb_set().
find_processes_in_group([], Set, _Group) ->
    Set;
find_processes_in_group([{{InstanceId, TheName}, _} | Rest], Set, Group) ->
    if
        InstanceId =:= Group ->
            find_processes_in_group(Rest, gb_sets:add_element(TheName, Set), Group);
        true ->
            find_processes_in_group(Rest, Set, Group)
    end.

-spec toString(atom() | nonempty_string()) -> nonempty_string().
toString(X) when is_atom(X) ->
    atom_to_list(X);
toString(X) ->
    X.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
%% @doc Returns the pid of the process dictionary.
-spec get_pid() -> pid() | failed.
get_pid() ->
    case whereis(?MODULE) of
        undefined ->
            log:log(error, "[ PD ] call of get_pid undefined"),
            failed;
        PID ->
            %log:log(info, "[ PD ] find right pid"),
            PID
    end.
