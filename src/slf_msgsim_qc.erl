%%%-------------------------------------------------------------------
%%% @author Scott Lystig Fritchie <slfritchie@snookles.com>
%%% @copyright (C) 2011, Scott Lystig Fritchie
%%% @doc
%%% QuickCheck foundations for the message passing &amp; dropping simulator.
%%% @end
%%%
%%% This file is provided to you under the Apache License,
%%% Version 2.0 (the "License"); you may not use this file
%%% except in compliance with the License.  You may obtain
%%% a copy of the License at
%%%
%%%   http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing,
%%% software distributed under the License is distributed on an
%%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%%% KIND, either express or implied.  See the License for the
%%% specific language governing permissions and limitations
%%% under the License.
%%%-------------------------------------------------------------------

-module(slf_msgsim_qc).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").

%%% Generators

gen_scheduler_list(Module, NumClients, NumServers) ->
    Clients = lists:sublist(Module:all_clients(), 1, NumClients),
    Servers = lists:sublist(Module:all_servers(), 1, NumServers),
    Both = Clients ++ Servers,
    ?LET({L1, UnfairL, SlowProcs, Seed},
         {list(elements(Both)),
          gen_unfair_list(Both),
          frequency([{4, []},
                     {1, non_empty(list(elements(Both)))}]),
          gen_seed()},
         begin
             L2 = lists:filter(fun(X) -> not lists:member(X, SlowProcs) end,
                               UnfairL ++ L1),
             Missing = [Proc || Proc <- Both,
                                not lists:member(Proc, L2)],
             L2 ++ shuffle(Missing, Seed)
         end).

gen_unfair_list(L) ->
    frequency([{1, []},
               {1, ?LET(SubL, non_empty(list(elements(L))),
                        resize(80, list(elements(SubL))))},
               {1, ?LET(SubL, non_empty(list(elements(L))),
                        resize(500, list(elements(SubL))))}]).

gen_server_partitions(Module, ModProps, NumClients, NumServers) ->
    case proplists:get_value(disable_partitions, ModProps, false) of
        true ->
            [];
        false ->
            ?LET(Parts,
                 non_empty(list(gen_partition(Module, NumClients, NumServers))),
                 lists:flatten(Parts))
    end.

gen_partition(Module, NumClients, NumServers) ->
    Clients = lists:sublist(Module:all_clients(), 1, NumClients),
    Servers = lists:sublist(Module:all_servers(), 1, NumServers),
    Both = Clients ++ Servers,
    ?LET({Direction, Froms, Tos, Start, Len},
         {oneof([s_to_c, c_to_s, both]),
          my_list_elements(Both), my_list_elements(Both),
          gen_nat_nat2(10, 1), gen_nat_nat2(30, 1)},
         case Direction of
             s_to_c ->
                 [{partition, Froms, Tos, Start, Start + Len}];
             c_to_s ->
                 [{partition, Tos, Froms, Start, Start + Len}];
             both ->
                 [{partition, Froms, Tos, Start, Start + Len},
                  {partition, Tos, Froms, Start, Start + Len}]
         end).

gen_message_delays(Module, ModProps, NumClients, NumServers) ->
    case proplists:get_value(disable_delays, ModProps, false) of
        true ->
            [];
        false ->
            list(gen_delay(Module, NumClients, NumServers))
    end.

gen_delay(Module, NumClients, NumServers) ->
    Clients = lists:sublist(Module:all_clients(), 1, NumClients),
    Servers = lists:sublist(Module:all_servers(), 1, NumServers),
    Both = Clients ++ Servers,
    ?LET({Froms, Tos, Start, Len, DelayRounds},
         {my_list_elements(Both), my_list_elements(Both),
          gen_nat_nat2(10, 1), gen_nat_nat2(30, 1), nat()},
         {delay, lists:usort(Froms), lists:usort(Tos),
          Start, Start + Len, DelayRounds + 1}).

gen_nat_nat2(A, B) ->
    frequency([{A, nat()},
               {B, ?LET({X,Y}, {nat(), nat()}, (X+1)*(Y+1))}]).

gen_seed() ->
    noshrink({largeint(), largeint(), largeint()}).

gen_initial_counter() ->
    frequency([{10, 1},
               {10, nat()},
               { 1, ?LET({X, Y},
                         {nat(), nat()},
                         X * Y)}]).

shuffle(L, Seed) ->
    random:seed(Seed),
    lists:sort(fun(_, _) -> random:uniform(100) < 50 end, L).

apply_msg_drops(Rpcs, DropList) ->
    NumRpcs = length(Rpcs),
    T = lists:foldl(fun({drop, Nth, c_to_s}, DT) when Nth =< NumRpcs ->
                            RPC = element(Nth, DT),
                            setelement(Nth, DT,
                                       filter_drop(RPC, {drop_noop, RPC}));
                       ({drop, Nth, s_to_c}, DT)  when Nth =< NumRpcs ->
                            RPC = element(Nth, DT),
                            setelement(Nth, DT,
                                       filter_drop(RPC, {drop_reply, RPC}));
                       (_, DT) ->
                            DT
                    end, list_to_tuple(Rpcs), DropList),
    tuple_to_list(T).

filter_drop({_, _, sched_barrier} = Old, _New) ->
    Old;
filter_drop(_Old, New) ->
    New.

delete_all(X, L) ->
    [Y || Y <- L, Y /= X].

check_exact_msg_or_timeout(Clients, Predicted, Actual) ->
    lists:all(
      fun(Client) ->
              Pred = proplists:get_value(Client, Predicted),
              Act = proplists:get_value(Client, Actual),
              lists:all(fun({X, X}) ->               true;
                           ({_X, server_timeout}) -> true;
                           (_)                    -> false
                        end, lists:zip(Pred, Act))
      end, Clients).

prop_simulate(Module, ModProps) ->
    {MinClients, MaxClients, MinServers, MaxServers, MinKeys, MaxKeys} =
        get_settings(ModProps),
    ?FORALL({NumClients, NumServers, NumKeys} = F1,
            {my_choose(MinClients, MaxClients),
             my_choose(MinServers, MaxServers),
             my_choose(MinKeys, MaxKeys)},
    ?FORALL({Ops, ClientInits, ServerInits, SchedList,
             PartitionList, DelayList} = F2,
            {Module:gen_initial_ops(NumClients, NumServers, NumKeys, ModProps),
             Module:gen_client_initial_states(NumClients, ModProps),
             Module:gen_server_initial_states(NumServers, ModProps),
             gen_scheduler_list(Module, NumClients, NumServers),
             gen_server_partitions(Module, ModProps, NumClients, NumServers),
             gen_message_delays(Module, ModProps, NumClients, NumServers)},
            begin
                Sched0 = slf_msgsim:new_sim(ClientInits, ServerInits, Ops,
                                            SchedList, PartitionList,
                                            DelayList, Module, ModProps),
                {Runnable, Sched1} = slf_msgsim:run_scheduler(Sched0),
                Trc = slf_msgsim:get_trace(Sched1),
                UTrc = slf_msgsim:get_utrace(Sched1),
                Module:verify_property(NumClients, NumServers, ModProps,
                                       F1, F2, Ops,
                                       Sched0, Runnable, Sched1, Trc, UTrc)
            end
           )).

prop_mc_simulate(Module, ModProps) ->
    {MinClients, MaxClients, MinServers, MaxServers, MinKeys, MaxKeys} =
        get_settings(ModProps),
    ?FORALL({NumClients, NumServers, NumKeys} = _F1,
            {my_choose(MinClients, MaxClients),
             my_choose(MinServers, MaxServers),
             my_choose(MinKeys, MaxKeys)},
    ?FORALL({Ops, ClientInits, ServerInits} = _F2,
            {Module:gen_initial_ops(NumClients, NumServers, NumKeys, ModProps),
             Module:gen_client_initial_states(NumClients, ModProps),
             Module:gen_server_initial_states(NumServers, ModProps)},
            prop_mc_simulate2(Module, ModProps, NumClients, NumServers, NumKeys,
                              Ops, ClientInits, ServerInits)
    )).

prop_mc_simulate2(Module, ModProps, NumClients, NumServers, _NumKeys,
                  Ops, ClientInits, ServerInits) ->
    [begin catch unlink(whereis(Proc)),
           catch exit(whereis(Proc), kill)
     end || Proc <- Module:all_clients() ++ Module:all_servers()],
    erlang:yield(),
    Parent = self(),
    OpsD0 = orddict:from_list([{Cl,[]} ||
                                  {Cl,_,_} <- ClientInits ++ ServerInits]),
    OpsD = lists:foldl(fun({Cl, Op}, Dict) ->
                               orddict:append(Cl, Op, Dict)
                       end, OpsD0, Ops),
    ServerPids = [start_mc_proc(Parent, Module, server, Name,
                                orddict:fetch(Name, OpsD), InitState) ||
                     {Name, InitState, _} <- ServerInits],
    ClPids = [start_mc_proc(Parent, Module, client, Name,
                                orddict:fetch(Name, OpsD), InitState) ||
                     {Name, InitState, _} <- ClientInits],

    %% TODO: Figure out how to use mce_app:blah_then_verify()
    %% distrib_counter_2phase_vclocksetwatch_sim:mc_probe(end_sequential),

    [catch (Svr ! shutdown) || Svr <- ServerPids ++ ClPids],
    [begin catch unlink(whereis(Proc)),
           catch exit(whereis(Proc), kill)
     end || Proc <- Module:all_clients() ++ Module:all_servers()],
    true = Module:verify_mc_property(NumClients, NumServers, ModProps,
                                     x, x, Ops, [there_are_no_client_results]),
    ok.

get_settings(ModProps) ->
    {proplists:get_value(min_clients, ModProps, 1),
     proplists:get_value(max_clients, ModProps, 9),
     proplists:get_value(min_servers, ModProps, 1),
     proplists:get_value(max_servers, ModProps, 9),
     proplists:get_value(min_keys, ModProps, 1),
     proplists:get_value(max_keys, ModProps, 1)}.

my_choose(_, 0) ->
    0;
my_choose(N, M) ->
    choose(N, M).

my_list_elements([]) ->
    [];
my_list_elements(L) ->
    list(elements(L)).

set_self(Name) ->
    erlang:put({?MODULE, self}, Name).

get_self() ->
    erlang:get({?MODULE, self}).

mc_bang(Rcpt, Msg) ->
    %% Rcpt ! Msg.
    Send = fun() -> Rcpt ! Msg end,
    Drop = fun() -> mce_erl:probe({drop_msg, mc_self(), Rcpt, Msg}) end,
    mce_erl:choice([{Send, []}, {Drop, []}]).

mc_self() ->
    get_self().

start_mc_proc(Parent, Module, Type, Name, Ops, InitState) ->
    Pid = spawn_link(fun() ->
                        register(Name, self()),
                        set_self(Name),
                        receive {ping, From} -> From ! pong end,
                        StartFun = Module:startup(Type),
                        V = StartFun(Ops, InitState),
                        Parent ! {self(), V},
                        distrib_counter_2phase_vclocksetwatch_sim:mc_probe(
                          {process_done, mc_self(), V}),
                        eat_everything()
                end),
    Pid ! {ping, self()},
    receive pong -> pong end,
    Pid.

eat_everything() ->
    receive X ->
            distrib_counter_2phase_vclocksetwatch_sim:mc_probe(
              {eat_everything, mc_self(), X}),
            distrib_counter_2phase_vclocksetwatch_sim:mc_probe(
              {eat_everything, self(), X}),
            eat_everything()
    end.

