%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is Spice Telephony.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <athompson at spicecsm dot com>
%%	Micah Warren <mwarren at spicecsm dot com>
%%

%% @doc Module to spit a subset of the cpx_monitor data to an xml file 
%% periodically.
-module(cpx_monitor_passive).
-author(micahw).

-behaviour(gen_server).

-ifdef(EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("log.hrl").
-include("call.hrl").
-include("queue.hrl").
-include("agent.hrl").
-include_lib("stdlib/include/qlc.hrl").

-define(WRITE_INTERVAL, 60). % in seconds.
-ifdef(EUNIT).
-define(DETS, passive_cache_test).
-else.
-define(DETS, passive_cache).
-endif.

-type(xml_output() :: {xmlfile, string()}).
-type(queues() :: {queues, [string()]}).
-type(queue_groups() :: {queue_groups, [string()]}).
-type(agents() :: {agents, [string()]}).
-type(agent_profiles() :: {agent_profiles, [string()]}).
-type(output_filter() :: 
	xml_output() | 
	queues() | 
	queue_groups() | 
	agents() | 
	agent_profiles()).
-type(output_filters() :: [output_filter()]).
-type(output_name() :: string()).
-type(outputs() :: [{output_name(), output_filters()}]).
-type(outputs_option() :: {outputs, outputs()}).

-type(write_interval() :: {write_interval, pos_integer()}). % in seconds
-type(start_option() :: 
	outputs_option() |
	write_interval()).
	
-type(start_options() :: [start_option()]).

%% Dets data types
-type(dets_key() :: {'media' | 'agent', string()}).
-type(timestamp() :: integer()).
%-type(health_data() :: [{atom(), any()}]).
%-type(details() :: [{any(), any()}]).
%-type(historical_event() :: 'ivr' | 'queued' | 'handled' | 'ended').
%-type(time_list() :: [{historical_event(), pos_integer()}]).
-type(historical_key() :: {'inbound', 'queued'} | {'inbound', 'ivr'} | {'inbound', 'qabandoned'} | {'inbound', 'ivrabandoned'} | {'inbound', 'handled'} | 'outbound' | 'undefined').
%-type(historical_tuple() :: {dets_key(), time(), health_data(), details(), historical_key()}).

%% API
-export([
	start_link/1,
	start/1,
	stop/0,
	write_output/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(filter_state, {
	state = [] :: [{dets_key(), {timestamp(), historical_key()}}],
	agent_profiles = [] :: [{string(), [string()]}],
	queue_groups = [] :: [{string(), [string()]}],
	clients = [] :: [{string(), [any()]}]
}).

-record(filter, {
	file_output :: string(),
	max_age = max :: 'max' | pos_integer(),
	queues :: [string()] | 'all',
	queue_groups :: [string()] | 'all',
	agents :: [string()] | 'all',
	agent_profiles :: [string()] | 'all',
	clients :: [string()] | 'all',
	nodes :: [atom()] | 'all',
	output_as = json :: 'json' | 'xml',
	state = #filter_state{} :: #filter_state{}
}).

-record(state, {
	filters = [] :: [{string(), #filter{}}],
	interval = ?WRITE_INTERVAL :: pos_integer(),
	%agent_cache = [],
	%media_cache = [],
	timer :: any(),
	write_pids = [] :: [{pid(), string()}]
}).

-type(state() :: #state{}).
-define(GEN_SERVER, true).
-include("gen_spec.hrl").

%%====================================================================
%% API
%%====================================================================

-spec(start_link/1 :: (Options :: start_options()) -> {'ok', pid()}).
start_link(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Options, []).

-spec(start/1 :: (Options :: start_options()) -> {'ok', pid()}).
start(Options) ->
	gen_server:start({local, ?MODULE}, ?MODULE, Options, []).

-spec(stop/0 :: () -> 'ok').
stop() ->
	gen_server:cast(?MODULE, stop).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%--------------------------------------------------------------------
init(Options) ->
	process_flag(trap_exit, true),
	Subtest = fun(Message) ->
		%?DEBUG("passive sub testing message: ~p", [Message]),
		Type = case Message of
			{set, {{T, _}, _, _, _}} ->
				T;
			{drop, {T, _}} ->
				T
		end,
		case Type of
			media ->
				true;
			agent ->
				true;
			_ ->
				false
		end
	end,
	Interval = proplists:get_value(write_interval, Options, ?WRITE_INTERVAL) * 1000,
	Torec = fun({Name, Props}) ->
		Fileout = lists:append([proplists:get_value(file_output, Props, "."), "/", Name]),
		Filter = #filter{
			file_output = lists:append([Fileout, ".", atom_to_list(json)]),
			max_age = proplists:get_value(max_age, Props, max),
			queues = proplists:get_value(queues, Props, all),
			queue_groups = proplists:get_value(queue_groups, Props, all),
			agents = proplists:get_value(agents, Props, all),
			agent_profiles = proplists:get_value(agent_profiles, Props, all),
			clients = proplists:get_value(clients, Props, all),
			nodes = proplists:get_value(nodes, Props, all),
			output_as = json
		},
		{Name, Filter}
	end,
	Filters = lists:map(Torec, proplists:get_value(outputs, Options, [{"default", []}])),
	dets:open_file(?DETS, []),
	{ok, Agents} = cpx_monitor:get_health(agent),
	{ok, Medias} = cpx_monitor:get_health(media),
	cpx_monitor:subscribe(Subtest),
	lists:foreach(fun({K, H, D}) -> cache_event({set, {K, H, D, util:now()}}) end, lists:append(Agents, Medias)),
	%Agentcache = sort_agents(Agents),
	%Mediacache = create_queued_clients(Medias),
	{ok, Timer} = timer:send_after(Interval, write_output),
	?DEBUG("started", []),
	{ok, #state{
		filters = Filters,
		interval = Interval,
		timer = Timer
		%agent_cache = Agentcache,
		%media_cache = Mediacache
	}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%--------------------------------------------------------------------
handle_cast(stop, State) ->
	{stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%--------------------------------------------------------------------
handle_info(write_output, #state{filters = Filters} = State) ->
	?DEBUG("Writing output.", []),
	Qh = qlc:q([Key || {Key, Time, _Hp, _Details, _History} <- dets:table(?DETS), util:now() - Time > 86400]),
	Keys = qlc:e(Qh),
	lists:foreach(fun(K) -> dets:delete(?DETS, K) end, Keys),
	WritePids = lists:map(fun({Nom, _F} = Filter) ->
		Pid = spawn_link(?MODULE, write_output, [Filter]),
		{Pid, Nom}
	end, Filters),
	?DEBUG("das pids:  ~p", [WritePids]),
	Timer = erlang:send_after(State#state.interval, self(), write_output),
	{noreply, State#state{timer = Timer, write_pids = WritePids}};
handle_info({cpx_monitor_event, Event}, #state{filters = Filters} = State) ->
	Row = cache_event(Event),
	Newfilters = update_filter_states(Row, Filters),
	{noreply, State#state{filters = Newfilters}};
handle_info({'EXIT', Pid, Reason}, #state{write_pids = Pids} = State) ->
	case proplists:get_value(Pid, Pids) of
		undefined ->
			{noreply, State};
		Name ->
			case Reason of
				normal ->
					?DEBUG("output written for filter ~p", [Name]),
					ok;
				_Else ->
					?ERROR("output write for ~p exited abnormally:  ~p", [Name, Reason]),
					ok
			end,
			Newlist = proplists:delete(Pid, Pids),
			{noreply, State#state{write_pids = Newlist}}
	end;
handle_info(Info, State) ->
	?DEBUG("Someother info:  ~p", [Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%%--------------------------------------------------------------------
terminate(Reason, _State) ->
	?INFO("terminating due to ~p", [Reason]),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

cache_event({drop, {media, _Id} = Key}) ->
	Row = case dets:lookup(?DETS, Key) of
		[{Key, Time, Hp, Details, {inbound, History}}] ->
			Newhistory = History ++ [{ended, util:now()}],
			Newrow = {Key, Time, Hp, Details, {inbound, Newhistory}},
			dets:insert(?DETS, Newrow),
			Newrow;
		_Else ->
			{Key, none}
	end,
	Row;
cache_event({drop, {agent, _Id} = Key}) ->
	dets:delete(?DETS, Key),
	{Key, none};
cache_event({set, {{media, _Id} = Key, EventHp, EventDetails, EventTime}}) ->
	case dets:lookup(?DETS, Key) of
		[{Key, Time, _Hp, _Details, {inbound, History}}] ->
			case {proplists:get_value(queue, EventDetails), proplists:get_value(agent, EventDetails), History} of
				{undefined, undefined, []} ->
					% just update the hp and details.
					Newrow = {Key, Time, EventHp, EventDetails, {inbound, History}},
					dets:insert(?DETS, Newrow),
					Newrow;
				{undefined, undefined, _List} ->
					% either death in ivr or queue, can be figured out later
					Newrow = {Key, Time, EventHp, EventDetails, {inbound, History ++ [{ended, EventTime}]}},
					dets:insert(?DETS, Newrow),
					Newrow;
				{undefined, _Agent, List} when length(List) > 0, length(List) < 3 ->
					Newrow = {Key, Time, EventHp, EventDetails, {inbound, History ++ [{handled, EventTime}]}},
					dets:insert(?DETS, Newrow),
					Newrow;
				{_Queue, undefined, [{ivr, _}]} ->
					Newrow = {Key, Time, EventHp, EventDetails, {inbound, History ++ [{queued, EventTime}]}},
					dets:insert(?DETS, Newrow),
					Newrow;
				{_Queue, _Agent, _} ->
					?WARNING("both agent and queue defined, ignoring (~p)", [Key]),
					none
			end;
		[{Key, Time, _Hp, _Details, History}] ->
			% either undefined or outbound history, blind update.
			Newrow = {Key, Time, EventHp, EventDetails, History},
			dets:insert(?DETS, Newrow),
			Newrow;
		[] ->
			case {proplists:get_value(queue, EventDetails), proplists:get_value(direction, EventDetails)} of
				{undefined, outbound} ->
					Newrow = {Key, EventTime, EventHp, EventDetails, outbound},
					dets:insert(?DETS, Newrow),
					Newrow;
				{undefined, inbound} ->
					?INFO("Didn't find queue, but still inbound.  Assuming it's in ivr call:  ~p", [Key]),
					Newrow = {Key, EventTime, EventHp, EventDetails, {inbound, [{ivr, EventTime}]}},
					dets:insert(?DETS, {Key, EventTime, EventHp, EventDetails, {inbound, ivr}}),
					Newrow;
				{_Queue, inbound} ->
					% guess it went right to queue.  /shrug.
					Newrow = {Key, EventTime, EventHp, EventDetails, {inbound, [{queued, EventTime}]}},
					dets:insert(?DETS, Newrow),
					Newrow
			end
	end;
cache_event({set, {{agent, _Id} = Key, EventHp, EventDetails, EventTime}}) ->
	case dets:lookup(?DETS, Key) of
		[] ->
			dets:insert(?DETS, {Key, EventTime, EventHp, EventDetails, undefined}),
			{Key, EventTime, EventHp, EventDetails, undefined};
		[{Key, Time, Hp, Details, undefined}] ->
			dets:insert(?DETS, {Key, Time, EventHp, EventDetails, undefined}),
			{Key, Time, Hp, Details, undefined}
	end.

get_clients(Filter) ->
	QH = qlc:q([proplists:get_value(client, Details) || 
		{{Type, _Id}, _Time, _Hp, Details, _History} = Row <- dets:table(?DETS), 
		Type == media, 
		filter_row(Filter, Row)
	]),
	{_, Out} = lists:foldl(fun(I, {TestAcc, TrueAcc}) -> 
		case lists:member(I#client.id, TestAcc) of
			false ->
				{[I#client.id | TestAcc], [I, TrueAcc]};
			true ->
				{TestAcc, TrueAcc}
		end
	end, {[], []}, qlc:e(QH)),
	Out.

get_queue_groups(Filter) ->
	QH = qlc:q([proplists:get_value(queue, Details) || 
		{{Type, _Id}, _Time, _Hp, Details, _History} = Row <- dets:table(?DETS),
		Type == media,
		filter_row(Filter, Row),
		proplists:get_value(queue, Details) =/= undefined
	]),
	Dupped = qlc:e(QH),
	{Groups, _} = lists:foldl(fun(I, {Acc, Queues}) ->
		case lists:member(I, Queues) of
			true ->
				{Acc, Queues};
			false ->
				Group = case call_queue_config:get_queue(I) of
					Rec when is_record(Rec, call_queue) ->
						Rec#call_queue.group;
					_ ->
						"Default"
				end,
				case lists:member(Group, Acc) of
					true ->
						{Acc, Queues};
					false ->
						{[Group | Acc], [I | Queues]}
				end
		end
	end,
	{[], []},
	Dupped),
	Groups.

get_agent_profiles(Filter) ->
	QH = qlc:q([proplists:get_value(profile, Details) ||
		{{Type, _Id}, _Time, _Hp, Details, _Historyf} = Row <- dets:table(?DETS),
		Type == agent,
		filter_row(Filter, Row),
		proplists:get_value(profile, Details) =/= undefined
	]),
	Dupped = qlc:e(QH),
	lists:foldl(fun(I, Acc) ->
		case lists:member(I, Acc) of
			true ->
				Acc;
			false ->
				[I | Acc]
		end
	end,
	[], Dupped).

get_agents(Filter, Profile) ->
	QH = qlc:q([Row ||
		{{Type, _Id}, _Time, _Hp, Details, _History} = Row <- dets:table(?DETS),
		Type == agent,
		filter_row(Filter, Row),
		proplists:get_value(profile, Details) == Profile
	]),
	qlc:e(QH).

get_queues(Filter, Group) ->
	QH = qlc:q([proplists:get_value(queue, Details) || 
		{{Type, _Id}, _Time, _Hp, Details, _History} = Row <- dets:table(?DETS),
		Type == media,
		filter_row(Filter, Row),
		begin 
			Q = proplists:get_value(queue, Details),
			case call_queue_config:get_queue(Q) of
				#call_queue{group = Group} ->
					true;
				_ ->
					false
			end
		end
	]),
	Dupped = qlc:e(QH),
	lists:foldl(fun(I, Acc) ->
		case lists:member(I, Acc) of
			true ->
				Acc;
			false ->
				[I | Acc]
		end
	end,
	[], Dupped).

get_queued_medias(Filter, Queue) ->
	QH = qlc:q([Row || 
		{{Type, _Id}, _Time, _Hp, Details, _History} = Row <- dets:table(?DETS),
		Type == media,
		filter_row(Filter, Row),
		proplists:get_value(queue, Details) == Queue
	]),
	qlc:e(QH).

get_client_medias(Filter, Client) ->
	QH = qlc:q([Row ||
		{{Type, _Id}, _Time, _Hp, Details, _History} = Row <- dets:table(?DETS),
		Type == media,
		filter_row(Filter, Row),
		begin Testc = proplists:get_value(client, Details), Testc#client.label == Client end,
		proplists:get_value(agent, Details) == undefined
	]),
	qlc:e(QH).

update_filter_states(none, Filters) ->
	Filters;
update_filter_states({{media, _}, none}, Filters) ->
	Filters;
update_filter_states({{agent, _}, none}, Filters) ->
	Filters;
update_filter_states({{agent, _}, _, _, _, _}, Filters) ->
	Filters;
update_filter_states(Row, Filters) ->
	update_filter_states(Row, Filters, []).

update_filter_states(_Row, [], Acc) ->
	lists:reverse(Acc);
update_filter_states({{media, Id}, Time, _Hp, _Details, Histroy} = Row, [{Nom, #filter{state = State} = Filter} | Tail], Acc) ->
	Midstatistics = proplists_replace(Id, {Time, Histroy}, State#filter_state.state),
	Newstatistics = lists:filter(fun({_, {T, _}}) -> T > util:now() - 86400 end, Midstatistics),
	Newstate = State#filter_state{state = Newstatistics},
	update_filter_states(Row, Tail, [{Nom, Filter#filter{state = Newstate}} | Acc]).				

%% @doc If the row passes through the filter, return true.
filter_row(#filter{max_age = Seconds} = Filter, Row) when is_integer(Seconds) ->
	Now = util:now(),
	case (Now - Seconds) > element(2, Row) of
		true ->
			false;
		false ->
			filter_row(Filter#filter{max_age = max}, Row)
	end;
filter_row(#filter{max_age = {since, Seconds}} = Filter, Row) ->
	{_Date, {Hour, Min, Sec}} = erlang:localtime(),
	Diff = Sec + (Min * 60) + (Hour * 60 * 60) - Seconds,
	filter_row(Filter#filter{max_age = Diff}, Row);
filter_row(#filter{queues = all, queue_groups = all, agents = all, agent_profiles = all, clients = all, nodes = all}, _Row) ->
	true;
filter_row(Filter, {{media, _Id}, _Time, _Hp, Details, {_Direction, handled}}) ->
	#client{label = Client} = proplists:get_value(client, Details),
	case list_member(Client, Filter#filter.clients) of
		false ->
			false;
		true ->
			Agent = proplists:get_value(agent, Details),
			case list_member(Agent, Filter#filter.agents) of
				false ->
					false;
				true ->
					case agent_auth:get_agent(Agent) of
						{atomic, [#agent_auth{profile = Prof}]} ->
							list_member(Prof, Filter#filter.agent_profiles);
						_ ->
							false
					end
			end
	end;
filter_row(Filter, {{media, _Id}, _Time, _Hp, Details, {_Direction, Queued}}) when Queued =:= queued; Queued =:= qabandoned ->
	Node = proplists:get_value(node, Details),
	case list_member(Node, Filter#filter.nodes) of
		false ->
			false;
		true ->
			#client{label = Client} = proplists:get_value(client, Details),
			case list_member(Client, Filter#filter.clients) of
				false ->
					false;
				true ->
					Queue = proplists:get_value(queue, Details),
					case {list_member(Queue, Filter#filter.queues), Filter#filter.queue_groups} of
						{false, _} ->
							false;
						{true, all} ->
							true;
						{true, List} ->
							case call_queue_config:get_queue(Queue) of
								noexists ->
									false;
								#call_queue{group = Group} ->
									list_member(Group, List)
							end
					end
			end
	end;
filter_row(_Filter, {{media, _Id}, _Time, _Hp, _Details, _History}) ->
	false;
filter_row(Filter, {{agent, Agent}, _Time, _Hp, Details, _History}) ->
	Node = proplists:get_value(node, Details),
	case list_member(Node, Filter#filter.nodes) of
		false ->
			false;
		true ->
			case list_member(Agent, Filter#filter.agents) of
				false ->
					false;
				true ->
					case agent_auth:get_agent(Agent) of
						{atomic, [#agent_auth{profile = Prof}]} ->
							list_member(Prof, Filter#filter.agent_profiles);
						_ ->
							false
					end
			end
	end.

-spec(write_output/1 :: ({Nom :: string(), Filter :: #filter{}}) -> 'ok').
write_output({_Nom, #filter{state = FilterState, file_output = Fileout} = Filter}) ->
	Hourago = util:now() - 3600,
	Inbound = [X || 
		{_Key, {_Time, Hkey}} = X <- FilterState#filter_state.state, 
		element(1, Hkey) == inbound
	],
	Outbound = [X || 
		{_Key, {_Time, Hkey}} = X <- FilterState#filter_state.state, 
		element(1, Hkey) == outbound
	],
	Abandoned = [X || 
		{_Key, {_Time, Hkey}} = X <- FilterState#filter_state.state, 
		element(1, Hkey) == inbound, 
		is_abandon(element(2, Hkey))
	],
	HourInbound = [X || 
		{_Key, {Time, Hkey}} = X <- FilterState#filter_state.state, 
		element(1, Hkey) == inbound, 
		Time > Hourago
	],
	HourOutbound = [X || {_Key, {Time, Hkey}} = X <- FilterState#filter_state.state, element(1, Hkey) == outbound, Time > Hourago],
	HourAbn = [X || 
		{_Key, {Time, Hkey}} = X <- FilterState#filter_state.state, 
		element(1, Hkey) == inbound, 
		is_abandon(element(2, Hkey)),
		Time > Hourago
	],
	Clients = get_clients(Filter),
	ClientsJson = clients_to_json(Clients, Filter),
	Queugroups = get_queue_groups(Filter),
	QueuegroupJson = queuegroups_to_json(Queugroups, Filter),
	AgentProfiles = get_agent_profiles(Filter),
	AgentProfsJson = agentprofiles_to_json(AgentProfiles, Filter),
	Rawdata = get_all_media(Filter),
	{_, _, _, _, Rawjson} = medias_to_json(Rawdata),
	Json = {struct, [
		{<<"writeTime">>, util:now()},
		{<<"totalInbound">>, length(Inbound)},
		{<<"totalOutbound">>, length(Outbound)},
		{<<"totalAbandoned">>, length(Abandoned)},
		{<<"hourInbound">>, length(HourInbound)},
		{<<"hourOutbound">>, length(HourOutbound)},
		{<<"hourAbandoned">>, length(HourAbn)},
		{<<"clients_in_queues">>, ClientsJson},
		{<<"queueGroups">>, QueuegroupJson},
		{<<"agentProfiles">>, AgentProfsJson},
		{<<"rawdata">>, Rawjson}
	]},
	Out = mochijson2:encode(Json),
	{ok, File} = file:open(Fileout, [write, binary]),
	file:write(File, Out).	

get_all_media(Filter) ->
	QH = qlc:q([Row || Row <- dets:table(?DETS), element(1, element(1, Row)) == media]),
	List = qlc:e(QH),
	get_all_media(Filter, List, []).

get_all_media(_Filter, [], Acc) ->
	lists:reverse(Acc);
get_all_media(Filter, [Row | Tail], Acc) ->
	case filter_row(Filter, Row) of
		false ->
			get_all_media(Filter, Tail, Acc);
		true ->
			get_all_media(Filter, Tail, [Row | Acc])
	end.

clients_to_json(Clients, Filter) ->
	clients_to_json(Clients, Filter, []).

clients_to_json([], _Filter, Acc) ->
	lists:reverse(Acc);
clients_to_json([Client | Tail], Filter, Acc) ->
	Medias = get_client_medias(Filter, Client#client.label),
	{Oldest, TotalIn, TotalOut, TotalAbn, MediaJson} = medias_to_json(Medias),
	Label = case Client#client.label of
		undefined ->
			undefined;
		Else ->
			list_to_binary(Else)
	end,
	Json = {struct, [
		{<<"label">>, Label},
		{<<"oldestAge">>, Oldest},
		{<<"totalInbound">>, TotalIn},
		{<<"totalOutbound">>, TotalOut},
		{<<"totalAbandoned">>, TotalAbn},
		{<<"medias">>, MediaJson}
	]},
	clients_to_json(Tail, Filter, [Json | Acc]).

medias_to_json(Rows) ->
	Time = util:now(),
	medias_to_json(Rows, {Time, 0, 0, 0, []}).

medias_to_json([], {Time, In, Out, Abn, Acc}) ->
	{Time, In, Out, Abn, lists:reverse(Acc)};
medias_to_json([{{media, Id}, Time, _Hp, Details, HistoricalKey} | Tail], {CurTime, In, Out, Abn, Acc}) ->
	Newtime = case Time < CurTime of
		true ->
			Time;
		false ->
			CurTime
	end,
	Eventtimes = case HistoricalKey of
		{inbound, Events} ->
			Events;
		_ ->
			[]
	end,
	NewHead = {struct, lists:append([
		{<<"id">>, list_to_binary(Id)},
		{<<"time">>, Time},
		{<<"brand">>, begin C = proplists:get_value(client, Details), case C#client.label of undefined -> undefined; _ -> list_to_binary(C#client.label) end end},
		{<<"node">>, proplists:get_value(node, Details)},
		{<<"type">>, proplists:get_value(type, Details)},
		{<<"priority">>, proplists:get_value(priority, Details)}
	], Eventtimes)},
	{Newin, Newout, Newabn} = case HistoricalKey of
		{'inbound', Abandoned} ->
			case is_abandon(Abandoned) of
				true ->
					{In + 1, Out, Abn + 1};
				false ->
					{In + 1, Out, Abn}
			end;
		outbound ->
			{In, Out + 1, Abn};
		_ ->
			{In, Out, Abn}
	end,
	medias_to_json(Tail, {Newtime, Newin, Newout, Newabn, [NewHead | Acc]}).

queuegroups_to_json(Groups, Filter) ->
	queuegroups_to_json(Groups, Filter, []).

queuegroups_to_json([], _Filter, Acc) ->
	lists:reverse(Acc);
queuegroups_to_json([Group | Tail], Filter, Acc) ->
	Queues = get_queues(Filter, Group),
	QueuesJson = queues_to_json(Queues, Filter),
	Json = {struct, [
		{<<"name">>, list_to_binary(Group)},
		{<<"queues">>, QueuesJson}
	]},
	queuegroups_to_json(Tail, Filter, [Json | Acc]).

queues_to_json(Queues, Filter) ->
	queues_to_json(Queues, Filter, []).

queues_to_json([], _Filter, Acc) ->
	lists:reverse(Acc);
queues_to_json([Queue | Tail], Filter, Acc) ->
	Medias = get_queued_medias(Filter, Queue),
	{Oldest, TotalIn, TotalOut, TotalAbn, MediaJson} = medias_to_json(Medias),
	Json = {struct, [
		{<<"name">>, list_to_binary(Queue)},
		{<<"oldestAge">>, Oldest},
		{<<"totalInbound">>, TotalIn},
		{<<"totalOutbound">>, TotalOut},
		{<<"totalAbandoned">>, TotalAbn},
		{<<"medias">>, MediaJson}
	]},
	queues_to_json(Tail, Filter, [Json | Acc]).

agentprofiles_to_json(Profiles, Filter) ->
	agentprofiles_to_json(Profiles, Filter, []).

agentprofiles_to_json([], _Filter, Acc) ->
	lists:reverse(Acc);
agentprofiles_to_json([Profile | Tail], Filter, Acc) ->
	Agents = get_agents(Filter, Profile),
	{Avail, Rel, Busy, AgentJson} = agents_to_json(Agents),
	Json = {struct, [
		{<<"name">>, list_to_binary(Profile)},
		{<<"available">>, Avail},
		{<<"released">>, Rel},
		{<<"incall">>, Busy},
		{<<"agents">>, AgentJson}
	]},
	agentprofiles_to_json(Tail, Filter, [Json | Acc]).

agents_to_json(Rows) ->
	agents_to_json(Rows, {0, 0, 0}, []).

agents_to_json([], {Avail, Rel, Busy}, Acc) ->
	{Avail, Rel, Busy, lists:reverse(Acc)};
agents_to_json([{{agent, Id}, _Time, _Hp, Details, _HistoryKey} | Tail], {Avail, Rel, Busy}, Acc) ->
	{Newcounts, State, Statedata} = case {proplists:get_value(state, Details), proplists:get_value(statedata, Details)} of
		{idle, {}} ->
			{{Avail + 1, Rel, Busy}, idle, false};
		{released, {RelId, default, Bias}} ->
			Data = {struct, [
				{<<"id">>, list_to_binary(RelId)},
				{<<"label">>, default},
				{<<"bias">>, Bias}
			]},
			{{Avail, Rel + 1, Busy}, released, Data};
		{released, {RelId, Label, Bias}} ->
			Data = {struct, [
				{<<"id">>, list_to_binary(RelId)},
				{<<"label">>, list_to_binary(Label)},
				{<<"bias">>, Bias}
			]},
			{{Avail, Rel + 1, Busy}, released, Data};
		{Statename, Media} when is_record(Media, call) ->
			Qh = qlc:q([Row ||
				{{Type, Idgen}, _Timegen, _Hpgen, _Detailsgen, _History} = Row <- dets:table(?DETS),
				Type == media,
				Idgen == Media#call.id
			]),
			{_, _, _, _, [Datajson]} = case qlc:e(Qh) of
				[] ->
					{undefined, [undefined]};
				[T] ->
					medias_to_json([T])
			end,
%			Data = {struct, [
%				{<<"client">>, case Client#client.label of undefined -> undefined; _ -> list_to_binary(Client#client.label) end},
%				{<<"mediaType">>, Media#call.type},
%				{<<"mediaId">>, list_to_binary(Media#call.id)},
%				{<<"timeQueued">>, Timequeue}
%			]},
			{{Avail, Rel, Busy + 1}, Statename, Datajson};
		{Statename, _Otherdata} ->
			{{Avail, Rel, Busy + 1}, Statename, false}
	end,
	NewHead = {struct, [
		{<<"id">>, list_to_binary(Id)},
		{<<"login">>, list_to_binary(proplists:get_value(login, Details))},
		{<<"node">>, proplists:get_value(node, Details)},
		{<<"lastchange">>, element(2, proplists:get_value(lastchange, Details))},
		{<<"state">>, State},
		{<<"stateData">>, Statedata}
	]},
	agents_to_json(Tail, Newcounts, [NewHead | Acc]).

proplists_replace(Key, Value, List) ->
	Mid = proplists:delete(Key, List),
	[{Key, Value} | Mid].

list_member(_Member, all) ->
	true;
list_member(Member, List) ->
	lists:member(Member, List).

is_abandon([{ended, _}]) ->
	true;
is_abandon([{ivr, _}, {ended, _}]) ->
	true;
is_abandon([{queued, _}, {ended, _}]) ->
	true;
is_abandon([{ivr, _}, {queued, _}, {ended, _}]) ->
	true;
is_abandon(_) ->
	false.

-ifdef(EUNIT).

filter_row_test_() ->
	{setup,
	fun() ->
		mnesia:create_schema([node()]),
		mnesia:start(),
		call_queue_config:build_tables(),
		agent_auth:build_tables(),
		agent_auth:add_agent("agent1", "test", [], agent, "profile1"),
		agent_auth:add_agent("agent2", "test", [], agent, "profile2"),
		call_queue_config:new_queue("queue1", 1, [], [], "queue_group1"),
		call_queue_config:new_queue("queue2", 1, [], [], "queue_group1"),
		call_queue_config:new_queue("queue3", 1, [], [], "queue_group2"),
		call_queue_config:new_queue("queue4", 1, [], [], "queue_group2"),
		Client1 = #client{
			id = "1",
			label = "client1"
		},
		Client2 = #client{
			id = "2",
			label = "client2"
		},
		Rows = [
			{{media, "media-c1-q1"}, 5, [], [{queue, "queue1"}, {client, Client1}], {inbound, queued}},
			{{media, "media-c1-q2"}, 5, [], [{queue, "queue2"}, {client, Client1}], {inbound, queued}},
			{{media, "media-c1-q3"}, 5, [], [{queue, "queue3"}, {client, Client1}], {inbound, queued}},
			{{media, "media-c1-q4"}, 5, [], [{queue, "queue4"}, {client, Client1}], {inbound, queued}},
			{{media, "media-c2-q1"}, 5, [], [{queue, "queue1"}, {client, Client2}], {inbound, queued}},
			{{media, "media-c2-q2"}, 5, [], [{queue, "queue2"}, {client, Client2}], {inbound, queued}},
			{{media, "media-c2-q3"}, 5, [], [{queue, "queue3"}, {client, Client2}], {inbound, queued}},
			{{media, "media-c2-q4"}, 5, [], [{queue, "queue4"}, {client, Client2}], {inbound, queued}},
			{{media, "media-c1-a1"}, 5, [], [{agent, "agent1"}, {client, Client1}], {inbound, handled}},
			{{media, "media-c2-a2"}, 5, [], [{agent, "agent2"}, {client, Client2}], {inbound, handled}},
			{{agent, "agent1"}, 5, [], [{profile, "profile1"}], undefined},
			{{agent, "agent2"}, 5, [], [{profile, "profile2"}], undefined}
		],
		DoFilter = fun(Filter) ->
			Test = fun(R, Acc) ->
				case filter_row(Filter, R) of
					true ->
						[element(1, R) | Acc];
					false ->
						Acc
				end
			end,
			lists:sort(lists:foldl(Test, [], Rows))
		end,
		{Rows, DoFilter}
	end,
	fun(_) ->
		Queues = ["queue1", "queue2", "queue3", "queue4"],
		lists:foreach(fun(Q) -> call_queue_config:destroy_queue(Q) end, Queues),
		mnesia:stop(),
		mnesia:delete_schema([node()])
	end,
	fun({Rows, DoFilter}) ->
		[{"filter with all set to, well, all",
		fun() ->
			Filter = #filter{
				clients = all,
				queues = all,
				queue_groups = all,
				agents = all,
				agent_profiles = all,
				nodes = all
			},
			Out = lists:map(fun(R) -> filter_row(Filter, R) end, Rows),
			?assert(lists:all(fun(In) -> In end, Out))
		end},
		{"filter by client only",
		fun() ->
			Filter = #filter{
				nodes = all,
				clients = ["client1"],
				queues = all,
				queue_groups = all,
				agents = all,
				agent_profiles = all
			},
			Expected = lists:sort([
				{media, "media-c1-a1"},
				{media, "media-c1-q1"},
				{media, "media-c1-q2"},
				{media, "media-c1-q3"},
				{media, "media-c1-q4"},
				{agent, "agent1"},
				{agent, "agent2"}
			]),
			Filtered = DoFilter(Filter),
			?assertEqual(Expected, Filtered)
		end},
		{"filter by queue only",
		fun() ->
			Filter = #filter{
				nodes = all,
				clients = all,
				queues = ["queue1"],
				queue_groups = all,
				agents = all,
				agent_profiles = all
			},
			Expected = lists:sort([
				{media, "media-c1-q1"},
				{media, "media-c2-q1"},
				{agent, "agent1"},
				{agent, "agent2"},
				{media, "media-c1-a1"},
				{media, "media-c2-a2"}
			]),
			Filtered = DoFilter(Filter),
			?assertEqual(Expected, Filtered)
		end},
		{"filter by queue group only",
		fun() ->
			Filter = #filter{
				nodes = all,
				clients = all,
				queues = all,
				queue_groups = ["queue_group1"],
				agents = all,
				agent_profiles = all
			},
			Expected = lists:sort([
				{media, "media-c1-q1"},
				{media, "media-c1-q2"},
				{media, "media-c2-q1"},
				{media, "media-c2-q2"},
				{media, "media-c1-a1"},
				{media, "media-c2-a2"},
				{agent, "agent1"},
				{agent, "agent2"}
			]),
			Filtered = DoFilter(Filter),
			?assertEqual(Expected, Filtered)
		end},
		{"filter by agent only",
		fun() ->
			Filter = #filter{
				nodes = all,
				clients = all,
				queue_groups = all,
				queues = all,
				agents = ["agent1"],
				agent_profiles = all
			},
			Expected = lists:sort([
				{media, "media-c1-q1"}, 
				{media, "media-c1-q2"}, 
				{media, "media-c1-q3"}, 
				{media, "media-c1-q4"}, 
				{media, "media-c2-q1"}, 
				{media, "media-c2-q2"}, 
				{media, "media-c2-q3"}, 
				{media, "media-c2-q4"}, 
				{media, "media-c1-a1"}, 
				{agent, "agent1"}
			]),
			Filtered = DoFilter(Filter),
			?assertEqual(Expected, Filtered)
		end},
		{"filter by agent_profile only",
		fun() ->
			Filter = #filter{
				nodes = all,
				clients = all,
				queue_groups = all,
				queues = all,
				agents = all,
				agent_profiles = ["profile2"]
			},
			Expected = lists:sort([
				{media, "media-c1-q1"}, 
				{media, "media-c1-q2"}, 
				{media, "media-c1-q3"}, 
				{media, "media-c1-q4"}, 
				{media, "media-c2-q1"}, 
				{media, "media-c2-q2"}, 
				{media, "media-c2-q3"}, 
				{media, "media-c2-q4"}, 
				{media, "media-c2-a2"}, 
				{agent, "agent2"}
			]),
			Filtered = DoFilter(Filter),
			?assertEqual(Expected, Filtered)
		end},
		{"filter by queues and client",
		fun() ->
			Filter = #filter{
				nodes = all,
				clients = ["client1"],
				queue_groups = all,
				queues = ["queue1"],
				agents = all,
				agent_profiles = all
			},
			Expected = lists:sort([
				{media, "media-c1-q1"}, 
				{media, "media-c1-a1"}, 
				{agent, "agent1"},
				{agent, "agent2"}
			]),
			Filtered = DoFilter(Filter),
			?assertEqual(Expected, Filtered)
		end},
		{"filter by queues, client, and agent",
		fun() ->
			Filter = #filter{
				nodes = all,
				clients = ["client1"],
				queue_groups = all,
				queues = ["queue1"],
				agents = ["agent1"],
				agent_profiles = all
			},
			Expected = lists:sort([
				{media, "media-c1-q1"}, 
				{media, "media-c1-a1"}, 
				{agent, "agent1"}
			]),
			Filtered = DoFilter(Filter),
			?assertEqual(Expected, Filtered)
		end},
		{"filter by age",
		fun() ->
			Filter = #filter{
				max_age = 1,
				clients = all,
				queues = all,
				queue_groups = all,
				agents = all,
				agent_profiles = all,
				nodes = all
			},
			Expected = [],
			Filtered = DoFilter(Filter),
			?assertEqual(Expected, Filtered)
		end},
		{"filter since time (like midnight)",
		fun() ->
			TheFilter = #filter{
				max_age = {since, 0},
				clients = all,
				queues = all,
				queue_groups = all,
				agents = all,
				agent_profiles = all,
				nodes = all
			},
			Now = util:now(),
			{_Date, {Hour, Min, Sec}} = erlang:localtime(),
			Diff = Sec + (Min * 60) + (Hour * 60 * 60),
			Midnight = Now - Diff,
			TheRows = [
				{{media, "pre-midnight"}, Midnight - 100, [], [], {inbound, queued}},
				{{media, "post-midnight"}, Midnight + 100, [], [], {inbound, queued}}
			],
			Expected = [{{media, "post-midnight"}, Midnight + 100, [], [], {inbound, queued}}],
			Fun = fun(R, Acc) -> 
				case filter_row(TheFilter, R) of
					true ->
						[R | Acc];
					false ->
						Acc
				end
			end,
			Got = lists:foldl(Fun, [], TheRows),
			?assertEqual(Expected, Got)
		end},
		{"filter since time (like 2 minutes after midnight)",
		fun() ->
			TheFilter = #filter{
				max_age = {since, 120},
				clients = all,
				queues = all,
				queue_groups = all,
				agents = all,
				agent_profiles = all,
				nodes = all
			},
			Now = util:now(),
			{_Date, {Hour, Min, Sec}} = erlang:localtime(),
			Diff = Sec + (Min * 60) + (Hour * 60 * 60),
			Midnight = Now - Diff,
			TheRows = [
				{{media, "pre-midnight"}, Midnight - 60, [], [], {inbound, queued}},
				{{media, "midnight"}, Midnight, [], [], {inbound, queued}},
				{{media, "post-midnight-1"}, Midnight + 60, [], [], {inbound, queued}},
				{{media, "post-midnight-3"}, Midnight + 180, [], [], {inbound, queued}}
			],
			Expected = [{{media, "post-midnight-3"}, Midnight + 180, [], [], {inbound, queued}}],
			Fun = fun(R, Acc) -> 
				case filter_row(TheFilter, R) of
					true ->
						[R | Acc];
					false ->
						Acc
				end
			end,
			Got = lists:foldl(Fun, [], TheRows),
			?assertEqual(Expected, Got)
		end}]
	end}.

qlc_test_() ->
	{setup,
	fun() ->
		dets:open_file(?DETS, []),
		dets:delete_all_objects(?DETS),
		Client1 = #client{
			id = "1",
			label = "client1"
		},
		Client2 = #client{
			id = "2",
			label = "client2"
		},
		Rows = [
			{{media, "media-c1-q1"}, 5, [], [{queue, "queue1"}, {client, Client1}], {inbound, queued}},
			{{media, "media-c1-q2"}, 5, [], [{queue, "queue2"}, {client, Client1}], {inbound, queued}},
			{{media, "media-c1-q3"}, 5, [], [{queue, "queue3"}, {client, Client1}], {inbound, queued}},
			{{media, "media-c1-q4"}, 5, [], [{queue, "queue4"}, {client, Client1}], {inbound, queued}},
			{{media, "media-c2-q1"}, 5, [], [{queue, "queue1"}, {client, Client2}], {inbound, queued}},
			{{media, "media-c2-q2"}, 5, [], [{queue, "queue2"}, {client, Client2}], {inbound, queued}},
			{{media, "media-c2-q3"}, 5, [], [{queue, "queue3"}, {client, Client2}], {inbound, queued}},
			{{media, "media-c2-q4"}, 5, [], [{queue, "queue4"}, {client, Client2}], {inbound, queued}},
			{{media, "media-c1-a1"}, 5, [], [{agent, "agent1"}, {client, Client1}], {inbound, handled}},
			{{media, "media-c2-a2"}, 5, [], [{agent, "agent2"}, {client, Client2}], {inbound, handled}},
			{{media, "media-undef-qq"}, 5, [], [{queue, "qq"}, {client, #client{id = undefined, label = undefined}}], {inbound, queued}},
			{{agent, "agent1"}, 5, [], [{profile, "profile1"}], undefined},
			{{agent, "agent2"}, 5, [], [{profile, "profile2"}], undefined}
		],
		lists:foreach(fun(R) -> dets:insert(?DETS, R) end, Rows),
		AllFilter = #filter{
			clients = all,
			queues = all,
			queue_groups = all,
			agents = all,
			agent_profiles = all,
			nodes = all
		},
		Getids = fun({{_Type, Id}, _, _, _, _}) ->
			Id
		end,
		{AllFilter, Client1, Client2, Getids}
	end,
	fun(_) ->
		ok
	end,
	fun({AllFilter, Client1, Client2, Getids}) ->
		[{"get medias with a given client",
		fun() ->
			Out = get_client_medias(AllFilter, Client1#client.label),
			?assertEqual(4, length(Out)),
			Expected = ["media-c1-q1", "media-c1-q2", "media-c1-q3", "media-c1-q4"],
			?assert(lists:all(fun(I) -> lists:member(I, Expected) end, lists:map(Getids, Out)))
		end},
		{"get medias with a given queue",
		fun() ->
			Out = get_queued_medias(AllFilter, "queue1"),
			?assertEqual(2, length(Out)),
			Expected = ["media-c1-q1", "media-c2-q1"],
			?assert(lists:all(fun(I) -> lists:member(I, Expected) end, lists:map(Getids, Out)))
		end},
		{"get media with an 'undefined' client",
		fun() ->
			[H | _] = Out = get_client_medias(AllFilter, undefined),
			?assertEqual(1, length(Out)),
			?assertEqual({media, "media-undef-qq"}, element(1, H))
		end}]
	end}.
	
-endif.