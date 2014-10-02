-module(inter_dc_repl_update).

-include("inter_dc_repl.hrl").
-include("floppy.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([init_state/1, enqueue_update/2, process_queue/1]).

init_state(Partition) ->
    {ok, #recvr_state{lastRecvd = orddict:new(), %% stores last OpId received
                      lastCommitted = orddict:new(),
                      recQ = orddict:new(),
                      partition=Partition}
    }.

enqueue_update(Transaction,
               State = #recvr_state{recQ = RecQ}) ->
    {_,{FromDC, _CommitTime},_,_} = Transaction,
    RecQNew = enqueue(FromDC, Transaction, RecQ),
    {ok, State#recvr_state{recQ = RecQNew}}.

%% Process one update from Q for each DC each Q.
%% This method must be called repeatedly
%% inorder to process all updates
process_queue(State=#recvr_state{recQ = RecQ}) ->
    NewState = orddict:fold(
                 fun(K, V, Res) ->
                         process_q_dc(K, V, Res)
                 end, State, RecQ),
    {ok, NewState}.

%% private functions

%%Takes one update from DC queue, checks whether its depV is satisfied and apply the update locally.
process_q_dc(Dc, DcQ, StateData=#recvr_state{lastCommitted = LastCTS,
                                             partition = Partition}) ->
    case queue:is_empty(DcQ) of
        false ->
            Transaction = queue:get(DcQ),
            {_TxId, CommitTime, VecSnapshotTime, _Ops} = Transaction,
            SnapshotTime = vectorclock:set_clock_of_dc(
                             Dc, 0, VecSnapshotTime),
            LocalDc = dc_utilities:get_my_dc_id(),
            {Dc, Ts} = CommitTime,
            %% Check for dependency of operations and write to log
            {ok, LC} = vectorclock:get_clock(Partition),
            Localclock = vectorclock:set_clock_of_dc(
                           Dc, 0,
                           vectorclock:set_clock_of_dc(
                             LocalDc, now_millisec(erlang:now()), LC)),
            case orddict:find(Dc, LastCTS) of  % Check for duplicate
                {ok, CTS} ->
                    if Ts >= CTS ->
                            check_and_update(SnapshotTime, Localclock,
                                             Transaction,
                                             Dc, DcQ, Ts, StateData ) ;
                       true ->
                            %% TODO: Not right way check duplicates
                            lager:info("Duplicate request"),
                            {ok, NewState} = finish_update_dc(
                                               Dc, DcQ, CTS, StateData),
                            %%Duplicate request, drop from queue
                            NewState
                    end;
                _ ->
                    check_and_update(SnapshotTime, Localclock, Transaction,
                                     Dc, DcQ, Ts, StateData)

            end;
        true ->
            StateData
    end.

check_and_update(SnapshotTime, Localclock, Transaction,
                 Dc, DcQ, Ts,
                 StateData = #recvr_state{partition = Partition} ) ->
    {_,_,_,Ops} = Transaction,
    Node = {Partition,node()},
    case check_dep(SnapshotTime, Localclock) of
        true ->
            lists:foreach(
              fun(Op) ->
                      Logrecord = Op#operation.payload,
                      case Logrecord#log_record.op_type of
                          noop ->
                              lager:debug("Heartbeat Received");
                          update ->
                              {Key,_Type,_Op} = Logrecord#log_record.op_payload,
                              LogId = log_utilities:get_logid_from_key(Key),
                              logging_vnode:append(Node, LogId, Logrecord);
                          _ -> %% prepare or commit
                              %%logging_vnode:append(Node, LogId, Logrecord);
                              lager:debug("Prepare/Commit record")
                              %%TODO Write this to log
                      end
              end, Ops),
            DownOps =
                clocksi_transaction_reader:get_update_ops_from_transaction(
                  Transaction),
            lists:foreach( fun(DownOp) ->
                                   Key = DownOp#clocksi_payload.key,
                                   ok = materializer_vnode:update_cache(Key, DownOp)
                           end, DownOps),
            lager:debug("Update from remote DC applied:",[payload]),
            %%TODO add error handling if append failed
            {ok, NewState} = finish_update_dc(
                               Dc, DcQ, Ts, StateData),
            {ok, _} = vectorclock:update_clock(Partition, Dc, Ts),
            riak_core_vnode_master:command(
              {Partition,node()}, calculate_stable_snapshot,
              vectorclock_vnode_master),
            riak_core_vnode_master:command({Partition, node()}, {process_queue},
                                           inter_dc_recvr_vnode_master),
            NewState;
        false ->
            lager:debug("Dep not satisfied ~p", [Transaction]),
            StateData
    end.

finish_update_dc(Dc, DcQ, Cts,
                 State=#recvr_state{lastCommitted = LastCTS, recQ = RecQ}) ->
    DcQNew = queue:drop(DcQ),
    RecQNew = set(Dc, DcQNew, RecQ),
    LastCommNew = set(Dc, Cts, LastCTS),
    {ok, State#recvr_state{lastCommitted = LastCommNew, recQ = RecQNew}}.

%% Checks depV against the committed timestamps
check_dep(DepV, Localclock) ->
    Result = vectorclock:ge(Localclock, DepV),
    Result.

%%Set a new value to the key.
set(Key, Value, Orddict) ->
    orddict:update(Key, fun(_Old) -> Value end, Value, Orddict).

%%Put a value to the Queue corresponding to Dc in RecQ orddict
enqueue(Dc, Data, RecQ) ->
    case orddict:find(Dc, RecQ) of
        {ok, Q} ->
            Q2 = queue:in(Data, Q),
            set(Dc, Q2, RecQ);
        error -> %key does not exist
            Q = queue:new(),
            Q2 = queue:in(Data,Q),
            set(Dc, Q2, RecQ)
    end.

now_millisec({MegaSecs, Secs, MicroSecs}) ->
    (MegaSecs * 1000000 + Secs) * 1000000 + MicroSecs.
