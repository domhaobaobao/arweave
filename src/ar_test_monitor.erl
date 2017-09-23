-module(ar_test_monitor).
-export([start/1, start/2, start/3, start/4, stop/1]).

%%% Represents a monitoring system for test network.
%%% Checks for forward progress on the network and fork events.
%%% Optionally notifies a listener when the network fails.

-record(state, {
	miners,
	listener,
	% How many seconds to waait between network polls.
	check_time,
	% How long should we wait for progression before reporting that
	% it has stopped?
	failure_time,
	time_since_progress = 0,
	log = []
}).

%% The default amount of time to wait before storing network state.
-define(DEFAULT_TIMEOUT, 15 * 60).

%% Start a monitor, given a list of mining nodes.
start(Miners) -> start(Miners, self()).
start(Miners, Listener) -> start(Miners, Listener, ?DEFAULT_TIMEOUT).
start(Miners, Listener, CheckTime) ->
	start(Miners, Listener, CheckTime, ?DEFAULT_TIMEOUT).
start(Miners, Listener, CheckTime, FailureTime) ->
	spawn(
		fun() ->
			server(
				#state {
					miners = Miners,
					listener = Listener,
					check_time = CheckTime,
					failure_time = FailureTime,
					log = [gather_results(Miners)]
				}
			)
		end
	).

%% Stop a monitor process (does not kill nodes or miners).
stop(PID) ->
	PID ! stop.

%% Main server loop
server(
		S = #state {
			miners = Miners,
			check_time = CheckTime,
			failure_time = FailureTime,
			time_since_progress = ProgTime,
			log = [Last|_] = Log
		}
	) ->
	receive stop -> ok
	after ar:scale_time(CheckTime * 1000) ->
		% Check for progress on the network.
		case gather_results(Miners) of
			Last when (ProgTime + CheckTime) >= FailureTime ->
				% No progress for longer than FailureTime, so reporting
				% that the network has stalled.
				end_test(S);
			Last ->
				% Increment time since progress and recurse.
				server(S#state { time_since_progress = ProgTime + CheckTime });
			New ->
				% A new state has been encountered. Print and store it.
				ar:report_console(ar_logging:format_log(New)),
				server(
					S#state {
						log = [New|Log],
						time_since_progress = 0
					}
				)
		end
	end.

%%% Utility functions

%% Ask all nodes for the current block, count the number of each result.
gather_results(Miners) ->
	lists:foldr(
		fun(B, Dict) ->
			case lists:keyfind(B, 1, Dict) of
				false -> [{B, 1}|Dict];
				{B, Num} ->
					lists:keyreplace(B, 1, Dict, {B, Num + 1})
			end
		end,
		[],
		lists:map(fun(Miner) -> hd(ar_node:get_blocks(Miner)) end, Miners)
	).

%% Stop all network nodes and report log to listener.
end_test(#state { log = Log, listener = Listener }) ->
	ar:report_console([{test, unknown}, stopping]),
	Listener ! {test_report, self(), stopped, Log},
	ok.