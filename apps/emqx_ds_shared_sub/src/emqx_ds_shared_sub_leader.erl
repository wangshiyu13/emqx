%%--------------------------------------------------------------------
%% Copyright (c) 2024 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_ds_shared_sub_leader).

-behaviour(gen_statem).

-include("emqx_ds_shared_sub_proto.hrl").
-include("emqx_ds_shared_sub_config.hrl").

-include_lib("emqx/include/emqx_mqtt.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("emqx/include/emqx_persistent_message.hrl").
-include_lib("snabbkaffe/include/trace.hrl").

-export([
    register/2,

    start_link/1,
    child_spec/1,
    id/1,

    callback_mode/0,
    init/1,
    handle_event/4,
    terminate/3
]).

-type share_topic_filter() :: emqx_persistent_session_ds:share_topic_filter().

-type group_id() :: share_topic_filter().

-type options() :: #{
    share_topic_filter := share_topic_filter()
}.

%% Agent states

-define(waiting_replaying, waiting_replaying).
-define(replaying, replaying).
-define(waiting_updating, waiting_updating).
-define(updating, updating).

-type agent_state() :: #{
    %% Our view of group_id sm's status
    %% it lags the actual state
    state := ?waiting_replaying | ?replaying | ?waiting_updating | ?updating,
    prev_version := emqx_maybe:t(emqx_ds_shared_sub_proto:version()),
    version := emqx_ds_shared_sub_proto:version(),
    agent_metadata := emqx_ds_shared_sub_proto:agent_metadata(),
    streams := list(emqx_ds:stream()),
    revoked_streams := list(emqx_ds:stream())
}.

-type progress() :: emqx_persistent_session_ds_shared_subs:progress().

-type stream_state() :: #{
    progress => progress(),
    rank => emqx_ds:stream_rank()
}.

%% TODO https://emqx.atlassian.net/browse/EMQX-12307
%% Some data should be persisted
-type data() :: #{
    %%
    %% Persistent data
    %%
    group_id := group_id(),
    topic := emqx_types:topic(),
    %% TODO https://emqx.atlassian.net/browse/EMQX-12575
    %% Implement some stats to assign evenly?
    stream_states := #{
        emqx_ds:stream() => stream_state()
    },
    rank_progress := emqx_ds_shared_sub_leader_rank_progress:t(),

    %%
    %% Ephemeral data, should not be persisted
    %%
    agents := #{
        emqx_ds_shared_sub_proto:agent() => agent_state()
    },
    stream_owners := #{
        emqx_ds:stream() => emqx_ds_shared_sub_proto:agent()
    }
}.

-export_type([
    options/0,
    data/0,
    progress/0
]).

%% States

-define(leader_waiting_registration, leader_waiting_registration).
-define(leader_active, leader_active).

%% Events

-record(register, {
    register_fun :: fun(() -> pid())
}).
-record(renew_streams, {}).
-record(renew_leases, {}).
-record(drop_timeout, {}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

register(Pid, Fun) ->
    gen_statem:call(Pid, #register{register_fun = Fun}).

%%--------------------------------------------------------------------
%% Internal API
%%--------------------------------------------------------------------

child_spec(#{share_topic_filter := ShareTopicFilter} = Options) ->
    #{
        id => id(ShareTopicFilter),
        start => {?MODULE, start_link, [Options]},
        restart => temporary,
        shutdown => 5000,
        type => worker
    }.

start_link(Options) ->
    gen_statem:start_link(?MODULE, [Options], []).

id(ShareTopicFilter) ->
    {?MODULE, ShareTopicFilter}.

%%--------------------------------------------------------------------
%% gen_statem callbacks
%%--------------------------------------------------------------------

callback_mode() -> [handle_event_function, state_enter].

init([#{share_topic_filter := #share{topic = Topic} = ShareTopicFilter} = _Options]) ->
    Data = #{
        group_id => ShareTopicFilter,
        topic => Topic,
        start_time => now_ms(),
        stream_states => #{},
        stream_owners => #{},
        agents => #{},
        rank_progress => emqx_ds_shared_sub_leader_rank_progress:init()
    },
    {ok, ?leader_waiting_registration, Data}.

%%--------------------------------------------------------------------
%% waiting_registration state

handle_event({call, From}, #register{register_fun = Fun}, ?leader_waiting_registration, Data) ->
    Self = self(),
    case Fun() of
        Self ->
            {next_state, ?leader_active, Data, {reply, From, {ok, Self}}};
        OtherPid ->
            {stop_and_reply, normal, {reply, From, {ok, OtherPid}}}
    end;
%%--------------------------------------------------------------------
%% repalying state
handle_event(enter, _OldState, ?leader_active, #{topic := Topic} = _Data) ->
    ?tp(debug, shared_sub_leader_enter_actve, #{topic => Topic}),
    {keep_state_and_data, [
        {{timeout, #renew_streams{}}, 0, #renew_streams{}},
        {{timeout, #renew_leases{}}, ?dq_config(leader_renew_lease_interval_ms), #renew_leases{}},
        {{timeout, #drop_timeout{}}, ?dq_config(leader_drop_timeout_interval_ms), #drop_timeout{}}
    ]};
%%--------------------------------------------------------------------
%% timers
%% renew_streams timer
handle_event({timeout, #renew_streams{}}, #renew_streams{}, ?leader_active, Data0) ->
    ?tp(debug, shared_sub_leader_timeout, #{timeout => renew_streams}),
    Data1 = renew_streams(Data0),
    {keep_state, Data1,
        {
            {timeout, #renew_streams{}},
            ?dq_config(leader_renew_streams_interval_ms),
            #renew_streams{}
        }};
%% renew_leases timer
handle_event({timeout, #renew_leases{}}, #renew_leases{}, ?leader_active, Data0) ->
    ?tp(debug, shared_sub_leader_timeout, #{timeout => renew_leases}),
    Data1 = renew_leases(Data0),
    {keep_state, Data1,
        {{timeout, #renew_leases{}}, ?dq_config(leader_renew_lease_interval_ms), #renew_leases{}}};
%% drop_timeout timer
handle_event({timeout, #drop_timeout{}}, #drop_timeout{}, ?leader_active, Data0) ->
    Data1 = drop_timeout_agents(Data0),
    {keep_state, Data1,
        {{timeout, #drop_timeout{}}, ?dq_config(leader_drop_timeout_interval_ms), #drop_timeout{}}};
%%--------------------------------------------------------------------
%% agent events
handle_event(
    info, ?agent_connect_leader_match(Agent, AgentMetadata, _TopicFilter), ?leader_active, Data0
) ->
    Data1 = connect_agent(Data0, Agent, AgentMetadata),
    {keep_state, Data1};
handle_event(
    info,
    ?agent_update_stream_states_match(Agent, StreamProgresses, Version),
    ?leader_active,
    Data0
) ->
    Data1 = with_agent(Data0, Agent, fun() ->
        update_agent_stream_states(Data0, Agent, StreamProgresses, Version)
    end),
    {keep_state, Data1};
handle_event(
    info,
    ?agent_update_stream_states_match(Agent, StreamProgresses, VersionOld, VersionNew),
    ?leader_active,
    Data0
) ->
    Data1 = with_agent(Data0, Agent, fun() ->
        update_agent_stream_states(Data0, Agent, StreamProgresses, VersionOld, VersionNew)
    end),
    {keep_state, Data1};
handle_event(
    info,
    ?agent_disconnect_match(Agent, StreamProgresses, Version),
    ?leader_active,
    Data0
) ->
    Data1 = with_agent(Data0, Agent, fun() ->
        disconnect_agent(Data0, Agent, StreamProgresses, Version)
    end),
    {keep_state, Data1};
%%--------------------------------------------------------------------
%% fallback
handle_event(enter, _OldState, _State, _Data) ->
    keep_state_and_data;
handle_event(Event, Content, State, _Data) ->
    ?SLOG(warning, #{
        msg => unexpected_event,
        event => Event,
        content => Content,
        state => State
    }),
    keep_state_and_data.

terminate(_Reason, _State, _Data) ->
    ok.

%%--------------------------------------------------------------------
%% Event handlers
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Renew streams

%% * Find new streams in DS
%% * Revoke streams from agents having too many streams
%% * Assign streams to agents having too few streams

renew_streams(
    #{
        start_time := StartTime,
        stream_states := StreamStates,
        topic := Topic,
        rank_progress := RankProgress0
    } = Data0
) ->
    TopicFilter = emqx_topic:words(Topic),
    StreamsWRanks = emqx_ds:get_streams(?PERSISTENT_MESSAGE_DB, TopicFilter, StartTime),

    %% Discard streams that are already replayed and init new
    {NewStreamsWRanks, RankProgress1} = emqx_ds_shared_sub_leader_rank_progress:add_streams(
        StreamsWRanks, RankProgress0
    ),
    {NewStreamStates, VanishedStreamStates} = update_progresses(
        StreamStates, NewStreamsWRanks, TopicFilter, StartTime
    ),
    Data1 = removed_vanished_streams(Data0, VanishedStreamStates),
    Data2 = Data1#{stream_states => NewStreamStates, rank_progress => RankProgress1},
    Data3 = revoke_streams(Data2),
    Data4 = assign_streams(Data3),
    ?SLOG(debug, #{
        msg => leader_renew_streams,
        topic_filter => TopicFilter,
        new_streams => length(NewStreamsWRanks)
    }),
    Data4.

update_progresses(StreamStates, NewStreamsWRanks, TopicFilter, StartTime) ->
    lists:foldl(
        fun({Rank, Stream}, {NewStreamStatesAcc, OldStreamStatesAcc}) ->
            case OldStreamStatesAcc of
                #{Stream := StreamData} ->
                    {
                        NewStreamStatesAcc#{Stream => StreamData},
                        maps:remove(Stream, OldStreamStatesAcc)
                    };
                _ ->
                    {ok, It} = emqx_ds:make_iterator(
                        ?PERSISTENT_MESSAGE_DB, Stream, TopicFilter, StartTime
                    ),
                    Progress = #{
                        iterator => It
                    },
                    {
                        NewStreamStatesAcc#{Stream => #{progress => Progress, rank => Rank}},
                        OldStreamStatesAcc
                    }
            end
        end,
        {#{}, StreamStates},
        NewStreamsWRanks
    ).

%% We just remove disappeared streams from anywhere.
%%
%% If streams disappear from DS during leader being in replaying state
%% this is an abnormal situation (we should receive `end_of_stream` first),
%% but clients clients are unlikely to report any progress on them.
%%
%% If streams disappear after long leader sleep, it is a normal situation.
%% This removal will be a part of initialization before any agents connect.
removed_vanished_streams(Data0, VanishedStreamStates) ->
    VanishedStreams = maps:keys(VanishedStreamStates),
    Data1 = lists:foldl(
        fun(Stream, #{stream_owners := StreamOwners0} = DataAcc) ->
            case StreamOwners0 of
                #{Stream := Agent} ->
                    #{streams := Streams0, revoked_streams := RevokedStreams0} =
                        AgentState0 = get_agent_state(Data0, Agent),
                    Streams1 = Streams0 -- [Stream],
                    RevokedStreams1 = RevokedStreams0 -- [Stream],
                    AgentState1 = AgentState0#{
                        streams => Streams1,
                        revoked_streams => RevokedStreams1
                    },
                    set_agent_state(DataAcc, Agent, AgentState1);
                _ ->
                    DataAcc
            end
        end,
        Data0,
        VanishedStreams
    ),
    Data2 = unassign_streams(Data1, VanishedStreams),
    Data2.

%% We revoke streams from agents that have too many streams (> desired_stream_count_per_agent).
%% We revoke only from replaying agents.
%% After revoking, no unassigned streams appear. Streams will become unassigned
%% only after agents report them as acked and unsubscribed.
revoke_streams(Data0) ->
    DesiredStreamsPerAgent = desired_stream_count_per_agent(Data0),
    Agents = replaying_agents(Data0),
    lists:foldl(
        fun(Agent, DataAcc) ->
            revoke_excess_streams_from_agent(DataAcc, Agent, DesiredStreamsPerAgent)
        end,
        Data0,
        Agents
    ).

revoke_excess_streams_from_agent(Data0, Agent, DesiredCount) ->
    #{streams := Streams0, revoked_streams := []} = AgentState0 = get_agent_state(Data0, Agent),
    RevokeCount = length(Streams0) - DesiredCount,
    AgentState1 =
        case RevokeCount > 0 of
            false ->
                AgentState0;
            true ->
                ?tp(debug, shared_sub_leader_revoke_streams, #{
                    agent => Agent,
                    agent_stream_count => length(Streams0),
                    revoke_count => RevokeCount,
                    desired_count => DesiredCount
                }),
                revoke_streams_from_agent(Data0, Agent, AgentState0, RevokeCount)
        end,
    set_agent_state(Data0, Agent, AgentState1).

revoke_streams_from_agent(
    Data,
    Agent,
    #{
        streams := Streams0, revoked_streams := []
    } = AgentState0,
    RevokeCount
) ->
    RevokedStreams = select_streams_for_revoke(Data, AgentState0, RevokeCount),
    Streams = Streams0 -- RevokedStreams,
    agent_transition_to_waiting_updating(Data, Agent, AgentState0, Streams, RevokedStreams).

select_streams_for_revoke(
    _Data, #{streams := Streams, revoked_streams := []} = _AgentState, RevokeCount
) ->
    %% TODO
    %% Some intellectual logic should be used regarding:
    %% * shard ids (better do not mix shards in the same agent);
    %% * stream stats (how much data was replayed from stream),
    %%   heavy streams should be distributed across different agents);
    %% * data locality (agents better preserve streams with data available on the agent's node)
    lists:sublist(shuffle(Streams), RevokeCount).

%% We assign streams to agents that have too few streams (< desired_stream_count_per_agent).
%% We assign only to replaying agents.
assign_streams(Data0) ->
    DesiredStreamsPerAgent = desired_stream_count_per_agent(Data0),
    Agents = replaying_agents(Data0),
    lists:foldl(
        fun(Agent, DataAcc) ->
            assign_lacking_streams(DataAcc, Agent, DesiredStreamsPerAgent)
        end,
        Data0,
        Agents
    ).

assign_lacking_streams(Data0, Agent, DesiredCount) ->
    #{streams := Streams0, revoked_streams := []} = get_agent_state(Data0, Agent),
    AssignCount = DesiredCount - length(Streams0),
    case AssignCount > 0 of
        false ->
            Data0;
        true ->
            ?tp(debug, shared_sub_leader_assign_streams, #{
                agent => Agent,
                agent_stream_count => length(Streams0),
                assign_count => AssignCount,
                desired_count => DesiredCount
            }),
            assign_streams_to_agent(Data0, Agent, AssignCount)
    end.

assign_streams_to_agent(Data0, Agent, AssignCount) ->
    StreamsToAssign = select_streams_for_assign(Data0, Agent, AssignCount),
    Data1 = set_stream_ownership_to_agent(Data0, Agent, StreamsToAssign),
    #{agents := #{Agent := AgentState0}} = Data1,
    #{streams := Streams0, revoked_streams := []} = AgentState0,
    Streams1 = Streams0 ++ StreamsToAssign,
    AgentState1 = agent_transition_to_waiting_updating(Data0, Agent, AgentState0, Streams1, []),
    set_agent_state(Data1, Agent, AgentState1).

select_streams_for_assign(Data0, _Agent, AssignCount) ->
    %% TODO
    %% Some intellectual logic should be used. See `select_streams_for_revoke/3`.
    UnassignedStreams = unassigned_streams(Data0),
    lists:sublist(shuffle(UnassignedStreams), AssignCount).

%%--------------------------------------------------------------------
%% renew_leases - send lease confirmations to agents

renew_leases(#{agents := AgentStates} = Data) ->
    ?tp(debug, shared_sub_leader_renew_leases, #{agents => maps:keys(AgentStates)}),
    ok = lists:foreach(
        fun({Agent, AgentState}) ->
            renew_lease(Data, Agent, AgentState)
        end,
        maps:to_list(AgentStates)
    ),
    Data.

renew_lease(#{group_id := GroupId}, Agent, #{state := ?replaying, version := Version}) ->
    ok = emqx_ds_shared_sub_proto:leader_renew_stream_lease(Agent, GroupId, Version);
renew_lease(#{group_id := GroupId}, Agent, #{state := ?waiting_replaying, version := Version}) ->
    ok = emqx_ds_shared_sub_proto:leader_renew_stream_lease(Agent, GroupId, Version);
renew_lease(#{group_id := GroupId} = Data, Agent, #{
    streams := Streams, state := ?waiting_updating, version := Version, prev_version := PrevVersion
}) ->
    StreamProgresses = stream_progresses(Data, Streams),
    ok = emqx_ds_shared_sub_proto:leader_update_streams(
        Agent, GroupId, PrevVersion, Version, StreamProgresses
    ),
    ok = emqx_ds_shared_sub_proto:leader_renew_stream_lease(Agent, GroupId, PrevVersion, Version);
renew_lease(#{group_id := GroupId}, Agent, #{
    state := ?updating, version := Version, prev_version := PrevVersion
}) ->
    ok = emqx_ds_shared_sub_proto:leader_renew_stream_lease(Agent, GroupId, PrevVersion, Version).

%%--------------------------------------------------------------------
%% Drop agents that stopped reporting progress

drop_timeout_agents(#{agents := Agents} = Data) ->
    Now = now_ms_monotonic(),
    lists:foldl(
        fun(
            {Agent,
                #{update_deadline := UpdateDeadline, not_replaying_deadline := NoReplayingDeadline} =
                    _AgentState},
            DataAcc
        ) ->
            case
                (UpdateDeadline < Now) orelse
                    (is_integer(NoReplayingDeadline) andalso NoReplayingDeadline < Now)
            of
                true ->
                    ?SLOG(debug, #{
                        msg => leader_agent_timeout,
                        now => Now,
                        update_deadline => UpdateDeadline,
                        not_replaying_deadline => NoReplayingDeadline,
                        agent => Agent
                    }),
                    drop_invalidate_agent(DataAcc, Agent);
                false ->
                    DataAcc
            end
        end,
        Data,
        maps:to_list(Agents)
    ).

%%--------------------------------------------------------------------
%% Handle a newly connected agent

connect_agent(
    #{group_id := GroupId, agents := Agents} = Data,
    Agent,
    AgentMetadata
) ->
    ?SLOG(debug, #{
        msg => leader_agent_connected,
        agent => Agent,
        group_id => GroupId
    }),
    case Agents of
        #{Agent := AgentState} ->
            ?tp(debug, shared_sub_leader_agent_already_connected, #{
                agent => Agent
            }),
            reconnect_agent(Data, Agent, AgentMetadata, AgentState);
        _ ->
            DesiredCount = desired_stream_count_for_new_agent(Data),
            assign_initial_streams_to_agent(Data, Agent, AgentMetadata, DesiredCount)
    end.

assign_initial_streams_to_agent(Data, Agent, AgentMetadata, AssignCount) ->
    InitialStreamsToAssign = select_streams_for_assign(Data, Agent, AssignCount),
    Data1 = set_stream_ownership_to_agent(Data, Agent, InitialStreamsToAssign),
    AgentState = agent_transition_to_initial_waiting_replaying(
        Data1, Agent, AgentMetadata, InitialStreamsToAssign
    ),
    set_agent_state(Data1, Agent, AgentState).

reconnect_agent(
    Data0,
    Agent,
    AgentMetadata,
    #{streams := OldStreams, revoked_streams := OldRevokedStreams} = _OldAgentState
) ->
    ?tp(debug, shared_sub_leader_agent_reconnect, #{
        agent => Agent,
        agent_metadata => AgentMetadata,
        inherited_streams => OldStreams
    }),
    AgentState = agent_transition_to_initial_waiting_replaying(
        Data0, Agent, AgentMetadata, OldStreams
    ),
    Data1 = set_agent_state(Data0, Agent, AgentState),
    %% If client reconnected gracefully then it either had already sent all the final progresses
    %% for the revoked streams (so `OldRevokedStreams` should be empty) or it had not started
    %% to replay them (if we revoked streams after it desided to reconnect). So we can safely
    %% unassign them.
    %%
    %% If client reconnects after a crash, then we wouldn't be here (the agent identity will be new).
    Data2 = unassign_streams(Data1, OldRevokedStreams),
    Data2.

%%--------------------------------------------------------------------
%% Handle stream progress updates from agent in replaying state

update_agent_stream_states(Data0, Agent, AgentStreamProgresses, Version) ->
    #{state := State, version := AgentVersion, prev_version := AgentPrevVersion} =
        AgentState0 = get_agent_state(Data0, Agent),
    case {State, Version} of
        {?waiting_updating, AgentPrevVersion} ->
            %% Stale update, ignoring
            Data0;
        {?waiting_replaying, AgentVersion} ->
            %% Agent finished updating, now replaying
            {Data1, AgentState1} = update_stream_progresses(
                Data0, Agent, AgentState0, AgentStreamProgresses
            ),
            AgentState2 = update_agent_timeout(AgentState1),
            AgentState3 = agent_transition_to_replaying(Agent, AgentState2),
            set_agent_state(Data1, Agent, AgentState3);
        {?replaying, AgentVersion} ->
            %% Common case, agent is replaying
            {Data1, AgentState1} = update_stream_progresses(
                Data0, Agent, AgentState0, AgentStreamProgresses
            ),
            AgentState2 = update_agent_timeout(AgentState1),
            set_agent_state(Data1, Agent, AgentState2);
        {OtherState, OtherVersion} ->
            ?tp(warning, unexpected_update, #{
                agent => Agent,
                update_version => OtherVersion,
                state => OtherState,
                our_agent_version => AgentVersion,
                our_agent_prev_version => AgentPrevVersion
            }),
            drop_invalidate_agent(Data0, Agent)
    end.

update_stream_progresses(
    #{stream_states := StreamStates0, stream_owners := StreamOwners} = Data0,
    Agent,
    AgentState0,
    ReceivedStreamProgresses
) ->
    {StreamStates1, ReplayedStreams} = lists:foldl(
        fun(#{stream := Stream, progress := Progress}, {StreamStatesAcc, ReplayedStreamsAcc}) ->
            case StreamOwners of
                #{Stream := Agent} ->
                    StreamData0 = maps:get(Stream, StreamStatesAcc),
                    case Progress of
                        #{iterator := end_of_stream} ->
                            Rank = maps:get(rank, StreamData0),
                            {maps:remove(Stream, StreamStatesAcc), ReplayedStreamsAcc#{
                                Stream => Rank
                            }};
                        _ ->
                            StreamData1 = StreamData0#{progress => Progress},
                            {StreamStatesAcc#{Stream => StreamData1}, ReplayedStreamsAcc}
                    end;
                _ ->
                    {StreamStatesAcc, ReplayedStreamsAcc}
            end
        end,
        {StreamStates0, #{}},
        ReceivedStreamProgresses
    ),
    Data1 = update_rank_progress(Data0, ReplayedStreams),
    Data2 = Data1#{stream_states => StreamStates1},
    AgentState1 = filter_replayed_streams(AgentState0, ReplayedStreams),
    {Data2, AgentState1}.

update_rank_progress(#{rank_progress := RankProgress0} = Data, ReplayedStreams) ->
    RankProgress1 = maps:fold(
        fun(Stream, Rank, RankProgressAcc) ->
            emqx_ds_shared_sub_leader_rank_progress:set_replayed({Rank, Stream}, RankProgressAcc)
        end,
        RankProgress0,
        ReplayedStreams
    ),
    Data#{rank_progress => RankProgress1}.

%% No need to revoke fully replayed streams. We do not assign them anymore.
%% The agent's session also will drop replayed streams itself.
filter_replayed_streams(
    #{streams := Streams0, revoked_streams := RevokedStreams0} = AgentState0,
    ReplayedStreams
) ->
    Streams1 = lists:filter(
        fun(Stream) -> not maps:is_key(Stream, ReplayedStreams) end,
        Streams0
    ),
    RevokedStreams1 = lists:filter(
        fun(Stream) -> not maps:is_key(Stream, ReplayedStreams) end,
        RevokedStreams0
    ),
    AgentState0#{
        streams => Streams1,
        revoked_streams => RevokedStreams1
    }.

clean_revoked_streams(
    Data0, _Agent, #{revoked_streams := RevokedStreams0} = AgentState0, ReceivedStreamProgresses
) ->
    FinishedReportedStreams = maps:from_list(
        lists:filtermap(
            fun
                (
                    #{
                        stream := Stream,
                        use_finished := true
                    }
                ) ->
                    {true, {Stream, true}};
                (_) ->
                    false
            end,
            ReceivedStreamProgresses
        )
    ),
    {FinishedStreams, StillRevokingStreams} = lists:partition(
        fun(Stream) ->
            maps:is_key(Stream, FinishedReportedStreams)
        end,
        RevokedStreams0
    ),
    Data1 = unassign_streams(Data0, FinishedStreams),
    AgentState1 = AgentState0#{revoked_streams => StillRevokingStreams},
    {AgentState1, Data1}.

unassign_streams(#{stream_owners := StreamOwners0} = Data, Streams) ->
    StreamOwners1 = maps:without(Streams, StreamOwners0),
    Data#{
        stream_owners => StreamOwners1
    }.

%%--------------------------------------------------------------------
%% Handle stream progress updates from agent in updating (VersionOld -> VersionNew) state

update_agent_stream_states(Data0, Agent, AgentStreamProgresses, VersionOld, VersionNew) ->
    #{state := State, version := AgentVersion, prev_version := AgentPrevVersion} =
        AgentState0 = get_agent_state(Data0, Agent),
    case {State, VersionOld, VersionNew} of
        {?waiting_updating, AgentPrevVersion, AgentVersion} ->
            %% Client started updating
            {Data1, AgentState1} = update_stream_progresses(
                Data0, Agent, AgentState0, AgentStreamProgresses
            ),
            AgentState2 = update_agent_timeout(AgentState1),
            {AgentState3, Data2} = clean_revoked_streams(
                Data1, Agent, AgentState2, AgentStreamProgresses
            ),
            AgentState4 =
                case AgentState3 of
                    #{revoked_streams := []} ->
                        agent_transition_to_waiting_replaying(Data1, Agent, AgentState3);
                    _ ->
                        agent_transition_to_updating(Agent, AgentState3)
                end,
            set_agent_state(Data2, Agent, AgentState4);
        {?updating, AgentPrevVersion, AgentVersion} ->
            {Data1, AgentState1} = update_stream_progresses(
                Data0, Agent, AgentState0, AgentStreamProgresses
            ),
            AgentState2 = update_agent_timeout(AgentState1),
            {AgentState3, Data2} = clean_revoked_streams(
                Data1, Agent, AgentState2, AgentStreamProgresses
            ),
            AgentState4 =
                case AgentState3 of
                    #{revoked_streams := []} ->
                        agent_transition_to_waiting_replaying(Data1, Agent, AgentState3);
                    _ ->
                        AgentState3
                end,
            set_agent_state(Data2, Agent, AgentState4);
        {?waiting_replaying, _, AgentVersion} ->
            {Data1, AgentState1} = update_stream_progresses(
                Data0, Agent, AgentState0, AgentStreamProgresses
            ),
            AgentState2 = update_agent_timeout(AgentState1),
            set_agent_state(Data1, Agent, AgentState2);
        {?replaying, _, AgentVersion} ->
            {Data1, AgentState1} = update_stream_progresses(
                Data0, Agent, AgentState0, AgentStreamProgresses
            ),
            AgentState2 = update_agent_timeout(AgentState1),
            set_agent_state(Data1, Agent, AgentState2);
        {OtherState, OtherVersionOld, OtherVersionNew} ->
            ?tp(warning, unexpected_update, #{
                agent => Agent,
                update_version_old => OtherVersionOld,
                update_version_new => OtherVersionNew,
                state => OtherState,
                our_agent_version => AgentVersion,
                our_agent_prev_version => AgentPrevVersion
            }),
            drop_invalidate_agent(Data0, Agent)
    end.

%%--------------------------------------------------------------------
%% Disconnect agent gracefully

disconnect_agent(Data0, Agent, AgentStreamProgresses, Version) ->
    case get_agent_state(Data0, Agent) of
        #{version := Version} ->
            ?tp(debug, shared_sub_leader_disconnect_agent, #{
                agent => Agent,
                version => Version
            }),
            Data1 = update_agent_stream_states(Data0, Agent, AgentStreamProgresses, Version),
            Data2 = drop_agent(Data1, Agent),
            Data2;
        _ ->
            ?tp(warning, shared_sub_leader_unexpected_disconnect, #{
                agent => Agent,
                version => Version
            }),
            Data1 = drop_agent(Data0, Agent),
            Data1
    end.

%%--------------------------------------------------------------------
%% Agent state transitions
%%--------------------------------------------------------------------

agent_transition_to_waiting_updating(
    #{group_id := GroupId} = Data,
    Agent,
    #{state := OldState, version := Version, prev_version := undefined} = AgentState0,
    Streams,
    RevokedStreams
) ->
    ?tp(debug, shared_sub_leader_agent_state_transition, #{
        agent => Agent,
        old_state => OldState,
        new_state => ?waiting_updating
    }),
    NewVersion = next_version(Version),

    AgentState1 = AgentState0#{
        state => ?waiting_updating,
        streams => Streams,
        revoked_streams => RevokedStreams,
        prev_version => Version,
        version => NewVersion
    },
    AgentState2 = renew_no_replaying_deadline(AgentState1),
    StreamProgresses = stream_progresses(Data, Streams),
    ok = emqx_ds_shared_sub_proto:leader_update_streams(
        Agent, GroupId, Version, NewVersion, StreamProgresses
    ),
    AgentState2.

agent_transition_to_waiting_replaying(
    #{group_id := GroupId} = _Data, Agent, #{state := OldState, version := Version} = AgentState0
) ->
    ?tp(debug, shared_sub_leader_agent_state_transition, #{
        agent => Agent,
        old_state => OldState,
        new_state => ?waiting_replaying
    }),
    ok = emqx_ds_shared_sub_proto:leader_renew_stream_lease(Agent, GroupId, Version),
    AgentState1 = AgentState0#{
        state => ?waiting_replaying,
        revoked_streams => []
    },
    renew_no_replaying_deadline(AgentState1).

agent_transition_to_initial_waiting_replaying(
    #{group_id := GroupId} = Data, Agent, AgentMetadata, InitialStreams
) ->
    ?tp(debug, shared_sub_leader_agent_state_transition, #{
        agent => Agent,
        old_state => none,
        new_state => ?waiting_replaying
    }),
    Version = 0,
    StreamProgresses = stream_progresses(Data, InitialStreams),
    Leader = this_leader(Data),
    ok = emqx_ds_shared_sub_proto:leader_lease_streams(
        Agent, GroupId, Leader, StreamProgresses, Version
    ),
    AgentState = #{
        metadata => AgentMetadata,
        state => ?waiting_replaying,
        version => Version,
        prev_version => undefined,
        streams => InitialStreams,
        revoked_streams => [],
        update_deadline => now_ms_monotonic() + ?dq_config(leader_session_update_timeout_ms)
    },
    renew_no_replaying_deadline(AgentState).

agent_transition_to_replaying(Agent, #{state := ?waiting_replaying} = AgentState) ->
    ?tp(debug, shared_sub_leader_agent_state_transition, #{
        agent => Agent,
        old_state => ?waiting_replaying,
        new_state => ?replaying
    }),
    AgentState#{
        state => ?replaying,
        prev_version => undefined,
        not_replaying_deadline => undefined
    }.

agent_transition_to_updating(Agent, #{state := ?waiting_updating} = AgentState0) ->
    ?tp(debug, shared_sub_leader_agent_state_transition, #{
        agent => Agent,
        old_state => ?waiting_updating,
        new_state => ?updating
    }),
    AgentState1 = AgentState0#{state => ?updating},
    renew_no_replaying_deadline(AgentState1).

%%--------------------------------------------------------------------
%% Helper functions
%%--------------------------------------------------------------------

now_ms() ->
    erlang:system_time(millisecond).

now_ms_monotonic() ->
    erlang:monotonic_time(millisecond).

renew_no_replaying_deadline(#{not_replaying_deadline := undefined} = AgentState) ->
    AgentState#{
        not_replaying_deadline => now_ms_monotonic() +
            ?dq_config(leader_session_not_replaying_timeout_ms)
    };
renew_no_replaying_deadline(#{not_replaying_deadline := _Deadline} = AgentState) ->
    AgentState;
renew_no_replaying_deadline(#{} = AgentState) ->
    AgentState#{
        not_replaying_deadline => now_ms_monotonic() +
            ?dq_config(leader_session_not_replaying_timeout_ms)
    }.

unassigned_streams(#{stream_states := StreamStates, stream_owners := StreamOwners}) ->
    Streams = maps:keys(StreamStates),
    AssignedStreams = maps:keys(StreamOwners),
    Streams -- AssignedStreams.

%% Those who are not connecting or updating, i.e. not in a transient state.
replaying_agents(#{agents := AgentStates}) ->
    lists:filtermap(
        fun
            ({Agent, #{state := ?replaying}}) ->
                {true, Agent};
            (_) ->
                false
        end,
        maps:to_list(AgentStates)
    ).

desired_stream_count_per_agent(#{agents := AgentStates} = Data) ->
    desired_stream_count_per_agent(Data, maps:size(AgentStates)).

desired_stream_count_for_new_agent(#{agents := AgentStates} = Data) ->
    desired_stream_count_per_agent(Data, maps:size(AgentStates) + 1).

desired_stream_count_per_agent(#{stream_states := StreamStates}, AgentCount) ->
    case AgentCount of
        0 ->
            0;
        _ ->
            StreamCount = maps:size(StreamStates),
            case StreamCount rem AgentCount of
                0 ->
                    StreamCount div AgentCount;
                _ ->
                    1 + StreamCount div AgentCount
            end
    end.

stream_progresses(#{stream_states := StreamStates} = _Data, Streams) ->
    lists:map(
        fun(Stream) ->
            StreamData = maps:get(Stream, StreamStates),
            #{
                stream => Stream,
                progress => maps:get(progress, StreamData)
            }
        end,
        Streams
    ).

next_version(Version) ->
    Version + 1.

shuffle(L0) ->
    L1 = lists:map(
        fun(A) ->
            {rand:uniform(), A}
        end,
        L0
    ),
    L2 = lists:sort(L1),
    {_, L} = lists:unzip(L2),
    L.

set_stream_ownership_to_agent(#{stream_owners := StreamOwners0} = Data, Agent, Streams) ->
    StreamOwners1 = lists:foldl(
        fun(Stream, Acc) ->
            Acc#{Stream => Agent}
        end,
        StreamOwners0,
        Streams
    ),
    Data#{
        stream_owners => StreamOwners1
    }.

set_agent_state(#{agents := Agents} = Data, Agent, AgentState) ->
    Data#{
        agents => Agents#{Agent => AgentState}
    }.

update_agent_timeout(AgentState) ->
    AgentState#{
        update_deadline => now_ms_monotonic() + ?dq_config(leader_session_update_timeout_ms)
    }.

get_agent_state(#{agents := Agents} = _Data, Agent) ->
    maps:get(Agent, Agents).

this_leader(_Data) ->
    self().

drop_agent(#{agents := Agents} = Data0, Agent) ->
    AgentState = get_agent_state(Data0, Agent),
    #{streams := Streams, revoked_streams := RevokedStreams} = AgentState,
    AllStreams = Streams ++ RevokedStreams,
    Data1 = unassign_streams(Data0, AllStreams),
    ?tp(debug, shared_sub_leader_drop_agent, #{agent => Agent}),
    Data1#{agents => maps:remove(Agent, Agents)}.

invalidate_agent(#{group_id := GroupId}, Agent) ->
    ok = emqx_ds_shared_sub_proto:leader_invalidate(Agent, GroupId).

drop_invalidate_agent(Data0, Agent) ->
    Data1 = drop_agent(Data0, Agent),
    ok = invalidate_agent(Data1, Agent),
    Data1.

with_agent(#{agents := Agents} = Data, Agent, Fun) ->
    case Agents of
        #{Agent := _} ->
            Fun();
        _ ->
            Data
    end.
