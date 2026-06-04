%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Supervised long-running Argos Translate worker shared between all sites.
%%
%% The worker owns one Python child process and serializes all requests to it.
%% Requests arriving while another request is pending are queued up to the
%% configured maximum queue length. Package administration requests are queued
%% in a priority queue and are handled before queued translation requests.
%% Translation requests are queued at the back of the normal FIFO queue.
%% Queued requests are skipped if their caller process has exited or if they
%% have already passed the caller's gen_server call timeout window.
%% @end

%% Copyright 2026 Marc Worrell
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(translate_argos_worker).

-behaviour(gen_server).

-author("Marc Worrell <marc@worrell.nl>").

-export([
    child_spec/3,
    install_package/3,
    packages/2,
    start_link/3,
    translate/5,
    translate_tags/5,
    update_packages/2
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-include_lib("zotonic_core/include/zotonic.hrl").

-define(KILL_TIMEOUT_SECS, 10).
-define(MAX_OUTPUT_SIZE, 10485760).

-record(state, {
    cmd :: [ string() ],
    python_pid :: pid() | undefined,
    os_pid :: integer() | undefined,
    stdout = <<>> :: binary(),
    pending = undefined :: undefined | {integer(), gen_server:from()},
    pending_timer = undefined :: undefined | reference(),
    admin_queue = queue:new() :: queue:queue(),
    queue = queue:new() :: queue:queue(),
    queue_len = 0 :: non_neg_integer(),
    max_queue = 100 :: non_neg_integer()
}).

-spec child_spec(Name, Cmd, MaxQueue) -> supervisor:child_spec() when
    Name :: atom(),
    Cmd :: [ string() ],
    MaxQueue :: non_neg_integer().
%% @doc Return the supervisor child spec for the long-running Python worker.
child_spec(Name, Cmd, MaxQueue) ->
    #{
        id => Name,
        start => {?MODULE, start_link, [Name, Cmd, MaxQueue]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

-spec start_link(Name, Cmd, MaxQueue) -> gen_server:start_ret() when
    Name :: atom(),
    Cmd :: [ string() ],
    MaxQueue :: non_neg_integer().
%% @doc Start the worker and register it under the supplied local name.
start_link(Name, Cmd, MaxQueue) ->
    gen_server:start_link({local, Name}, ?MODULE, {Cmd, MaxQueue}, []).

-spec translate(Name, SourceCode, TargetCode, Texts, Timeout) -> Result when
    Name :: atom(),
    SourceCode :: binary(),
    TargetCode :: binary(),
    Texts :: [ binary() ],
    Timeout :: pos_integer(),
    Result :: {ok, map()} | {error, term()}.
%% @doc Request plain text translation from the worker process.
translate(Name, SourceCode, TargetCode, Texts, Timeout) ->
    call(Name, {translate, SourceCode, TargetCode, Texts, Timeout}, Timeout).

-spec translate_tags(Name, SourceCode, TargetCode, Texts, Timeout) -> Result when
    Name :: atom(),
    SourceCode :: binary(),
    TargetCode :: binary(),
    Texts :: [ binary() ],
    Timeout :: pos_integer(),
    Result :: {ok, map()} | {error, term()}.
%% @doc Request translation where simple tags must be preserved.
translate_tags(Name, SourceCode, TargetCode, Texts, Timeout) ->
    call(Name, {translate_tags, SourceCode, TargetCode, Texts, Timeout}, Timeout).

-spec packages(Name, Timeout) -> Result when
    Name :: atom(),
    Timeout :: pos_integer(),
    Result :: {ok, map()} | {error, term()}.
%% @doc Request the list of supported Argos translation packages.
packages(Name, Timeout) ->
    call(Name, {packages, Timeout}, Timeout).

-spec install_package(Name, PackageName, Timeout) -> Result when
    Name :: atom(),
    PackageName :: binary(),
    Timeout :: pos_integer(),
    Result :: {ok, map()} | {error, term()}.
%% @doc Install or update one package in the Python Argos environment.
install_package(Name, PackageName, Timeout) ->
    call(Name, {install_package, PackageName, Timeout}, Timeout).

-spec update_packages(Name, Timeout) -> Result when
    Name :: atom(),
    Timeout :: pos_integer(),
    Result :: {ok, map()} | {error, term()}.
%% @doc Refresh the Argos package index.
update_packages(Name, Timeout) ->
    call(Name, {update_packages, Timeout}, Timeout).

%% @doc Call the gen_server and normalize common exits to error tuples.
call(Name, Request, Timeout) ->
    try
        gen_server:call(Name, Request, Timeout + 5000)
    catch
        exit:{timeout, _} ->
            {error, timeout};
        exit:{noproc, _} ->
            {error, not_started};
        exit:Reason ->
            {error, Reason}
    end.

%%%%%%%% Gen Server Functions %%%%%%%%

%% @doc Initialize the worker state and start Python immediately.
init({Cmd, MaxQueue}) ->
    process_flag(trap_exit, true),
    {ok, ensure_python(#state{ cmd = Cmd, max_queue = MaxQueue })}.

%% @doc Convert public API calls to JSON requests for the Python worker.
handle_call({translate, SourceCode, TargetCode, Texts, Timeout}, From, State) ->
    Request = #{
        <<"op">> => <<"translate">>,
        <<"from">> => SourceCode,
        <<"to">> => TargetCode,
        <<"texts">> => Texts
    },
    handle_request(back, Request, Timeout, From, State);
handle_call({translate_tags, SourceCode, TargetCode, Texts, Timeout}, From, State) ->
    Request = #{
        <<"op">> => <<"translate">>,
        <<"from">> => SourceCode,
        <<"to">> => TargetCode,
        <<"texts">> => Texts,
        <<"tags">> => true
    },
    handle_request(back, Request, Timeout, From, State);
handle_call({packages, Timeout}, From, State) ->
    handle_request(front, #{ <<"op">> => <<"packages">> }, Timeout, From, State);
handle_call({install_package, PackageName, Timeout}, From, State) ->
    handle_request(front, #{ <<"op">> => <<"install_package">>, <<"name">> => PackageName }, Timeout, From, State);
handle_call({update_packages, Timeout}, From, State) ->
    handle_request(front, #{ <<"op">> => <<"update_packages">> }, Timeout, From, State);
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

%% @doc Ignore asynchronous casts; this worker only uses calls and process messages.
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @doc Handle Python stdout, stderr, process exits, and request timeouts.
handle_info({stdout, OsPid, Data}, #state{ os_pid = OsPid, stdout = Stdout } = State) ->
    handle_stdout(<<Stdout/binary, Data/binary>>, State#state{ stdout = <<>> });
handle_info({stderr, OsPid, Data}, #state{ os_pid = OsPid } = State) ->
    log_stderr(Data),
    {noreply, State};
handle_info({'DOWN', OsPid, process, _Pid, Reason}, #state{ os_pid = OsPid } = State) ->
    State1 = reply_pending({error, #{ reason => python_down, detail => Reason }}, State),
    State2 = State1#state{ python_pid = undefined, os_pid = undefined, stdout = <<>> },
    {noreply, start_next_request(State2)};
handle_info({translate_timeout, ReqId}, #state{ pending = {ReqId, _From} } = State) ->
    State1 = reply_pending({error, timeout}, State),
    stop_python(State1),
    State2 = State1#state{ python_pid = undefined, os_pid = undefined, stdout = <<>> },
    {noreply, start_next_request(State2)};
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, State) ->
    {noreply, remove_queued_request(Monitor, State)};
handle_info(_Msg, State) ->
    {noreply, State}.

%% @doc Stop the child Python process when the Erlang worker terminates.
terminate(_Reason, State) ->
    stop_python(State),
    ok.

%% @doc Keep state unchanged during code upgrades.
code_change(_Vsn, State, _Extra) ->
    {ok, State}.

%%%%%%%% Internal Functions %%%%%%%%

%% @doc Start a request immediately or enqueue it while another request is pending.
handle_request(_Position, Request, Timeout, From, #state{ pending = undefined } = State) ->
    send_request(Request, Timeout, From, State);
handle_request(Position, Request, Timeout, From, State) ->
    enqueue_request(Position, Request, Timeout, From, State).

%% @doc Ensure Python is running, send one JSON request, and arm its timeout.
send_request(Request, Timeout, From, State) ->
    State1 = ensure_python(State),
    case State1#state.python_pid of
        undefined ->
            {reply, {error, python_not_started}, State1};
        Pid ->
            ReqId = erlang:unique_integer([positive, monotonic]),
            Payload = z_json:encode(Request#{ <<"id">> => ReqId }),
            ok = exec:send(Pid, <<Payload/binary, $\n>>),
            Timer = erlang:send_after(Timeout, self(), {translate_timeout, ReqId}),
            {noreply, State1#state{ pending = {ReqId, From}, pending_timer = Timer }}
    end.

%% @doc Queue a request, bounded by the configured maximum queue length.
enqueue_request(_Position, _Request, _Timeout, _From, #state{ queue_len = Len, max_queue = MaxQueue } = State) when Len >= MaxQueue ->
    {reply, {error, overload}, State};
enqueue_request(Position, Request, Timeout, From, State) ->
    Caller = caller_pid(From),
    Monitor = erlang:monitor(process, Caller),
    Expires = erlang:monotonic_time(millisecond) + Timeout + 5000,
    Item = {Request, Timeout, From, Caller, Monitor, Expires},
    {noreply, queue_request(Position, Item, State)}.


%% @doc Buffer stdout until complete JSON response lines are available.
handle_stdout(Data, State) when size(Data) =< ?MAX_OUTPUT_SIZE ->
    case binary:split(Data, <<"\n">>) of
        [Line, Rest] when Rest =/= <<>> ->
            State1 = handle_stdout_line(Line, State),
            handle_stdout(Rest, State1);
        [_] ->
            {noreply, State#state{ stdout = Data }};
        [Line, <<>>] ->
            {noreply, handle_stdout_line(Line, State)}
    end;
handle_stdout(_Data, State) ->
    State1 = reply_pending({error, output_too_large}, State),
    stop_python(State1),
    State2 = State1#state{ python_pid = undefined, os_pid = undefined, stdout = <<>> },
    {noreply, start_next_request(State2)}.

%% @doc Decode one stdout line and apply the Python response.
handle_stdout_line(<<>>, State) ->
    State;
handle_stdout_line(Line, State) ->
    try
        handle_python_response(z_json:decode(Line), State)
    catch
        error:Reason ->
            State1 = reply_pending({error, #{ reason => invalid_json, detail => Reason, stdout => Line }}, State),
            start_next_request(State1)
    end.

%% @doc Match a Python response to the pending caller and reply.
handle_python_response(#{ <<"id">> := ReqId, <<"translations">> := Translations }, #state{ pending = {ReqId, _From} } = State) ->
    start_next_request(reply_pending({ok, #{ <<"translations">> => Translations }}, State));
handle_python_response(#{ <<"id">> := ReqId, <<"error">> := Reason }, #state{ pending = {ReqId, _From} } = State) ->
    start_next_request(reply_pending({error, normalize_error(Reason)}, State));
handle_python_response(#{ <<"id">> := ReqId } = Response, #state{ pending = {ReqId, _From} } = State) ->
    start_next_request(reply_pending({ok, maps:remove(<<"id">>, Response)}, State));
handle_python_response(_Response, State) ->
    State.

%% @doc Normalize Python worker errors to atoms or structured error maps.
normalize_error(<<"argostranslate_import">>) -> argostranslate_import;
normalize_error(<<"translation">>) -> translation;
normalize_error(<<"invalid_op">>) -> invalid_op;
normalize_error(<<"invalid_id">>) -> invalid_id;
normalize_error(<<"invalid_language">>) -> invalid_language;
normalize_error(<<"invalid_texts">>) -> invalid_texts;
normalize_error(<<"language_pair">>) -> language_pair;
normalize_error(<<"packages">>) -> packages;
normalize_error(<<"update_packages">>) -> update_packages;
normalize_error(<<"invalid_package">>) -> invalid_package;
normalize_error(<<"package_not_found">>) -> package_not_found;
normalize_error(<<"install_package">>) -> install_package;
normalize_error(Reason) when is_binary(Reason) ->
    #{ reason => python_error, message => Reason };
normalize_error(Reason) ->
    Reason.

%% @doc Reply to the pending caller, if there is one.
reply_pending(_Reply, #state{ pending = undefined } = State) ->
    State;
reply_pending(Reply, #state{ pending = {_ReqId, From}, pending_timer = Timer } = State) ->
    cancel_timer(Timer),
    gen_server:reply(From, Reply),
    State#state{ pending = undefined, pending_timer = undefined }.

%% @doc Add an item to the priority or normal request queue.
queue_request(front, Item, State) ->
    State#state{
        admin_queue = queue:in(Item, State#state.admin_queue),
        queue_len = State#state.queue_len + 1
    };
queue_request(back, Item, State) ->
    State#state{
        queue = queue:in(Item, State#state.queue),
        queue_len = State#state.queue_len + 1
    }.

%% @doc Start the next queued request whose caller process is still alive.
start_next_request(#state{ pending = undefined } = State) ->
    case next_queued_request(State) of
        {{Request, Timeout, From, Caller, Monitor, Expires}, State1} ->
            erlang:demonitor(Monitor, [flush]),
            case is_process_alive(Caller) andalso queue_item_active(Expires) of
                true ->
                    case send_request(Request, Timeout, From, State1) of
                        {noreply, State2} -> State2;
                        {reply, Reply, State2} ->
                            gen_server:reply(From, Reply),
                            start_next_request(State2)
                    end;
                false ->
                    start_next_request(State1)
            end;
        empty ->
            State
    end;
start_next_request(State) ->
    State.

%% @doc Pop a package/admin request before normal translation requests.
next_queued_request(State) ->
    case queue:out(State#state.admin_queue) of
        {{value, Item}, Queue1} ->
            {Item, State#state{ admin_queue = Queue1, queue_len = State#state.queue_len - 1 }};
        {empty, _Queue} ->
            next_translation_request(State)
    end.

%% @doc Pop the next queued translation request.
next_translation_request(State) ->
    case queue:out(State#state.queue) of
        {{value, Item}, Queue1} ->
            {Item, State#state{ queue = Queue1, queue_len = State#state.queue_len - 1 }};
        {empty, _Queue} ->
            empty
    end.

%% @doc Check if a queued request is still inside the caller's call timeout.
queue_item_active(Expires) ->
    erlang:monotonic_time(millisecond) =< Expires.

%% @doc Remove queued requests for a caller process that has exited.
remove_queued_request(Monitor, State) ->
    {AdminQueue1, AdminRemoved} = remove_queued_request(Monitor, queue:out(State#state.admin_queue), queue:new(), 0),
    {Queue1, Removed} = remove_queued_request(Monitor, queue:out(State#state.queue), queue:new(), 0),
    State#state{
        admin_queue = AdminQueue1,
        queue = Queue1,
        queue_len = State#state.queue_len - AdminRemoved - Removed
    }.

%% @doc Rebuild the queue without the item matching a monitor reference.
remove_queued_request(Monitor, {{value, {_Request, _Timeout, _From, _Caller, Monitor, _Expires}}, Queue}, Acc, Removed) ->
    remove_queued_request(Monitor, queue:out(Queue), Acc, Removed + 1);
remove_queued_request(Monitor, {{value, Item}, Queue}, Acc, Removed) ->
    remove_queued_request(Monitor, queue:out(Queue), queue:in(Item, Acc), Removed);
remove_queued_request(_Monitor, {empty, _Queue}, Acc, Removed) ->
    {Acc, Removed}.

%% @doc Extract the caller process id from a gen_server call origin.
caller_pid({Pid, _Tag}) ->
    Pid.

%% @doc Cancel a request timeout timer if it was armed.
cancel_timer(undefined) ->
    ok;
cancel_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

%% @doc Start the Python process when it is not already running.
ensure_python(#state{ python_pid = undefined, cmd = Cmd } = State) ->
    case exec:run(Cmd, [stdin, stdout, stderr, monitor, {kill_timeout, ?KILL_TIMEOUT_SECS}]) of
        {ok, Pid, OsPid} ->
            State#state{ python_pid = Pid, os_pid = OsPid };
        {error, Reason} ->
            ?LOG_ERROR(#{
                in => ?MODULE,
                text => <<"Could not start Argos Translate Python process">>,
                result => error,
                reason => Reason
            }),
            State
    end;
ensure_python(State) ->
    State.

%% @doc Log Python stderr output, ignoring known harmless Argos warnings.
log_stderr(Data) ->
    Lines = binary:split(z_string:trim(Data), <<"\n">>, [global]),
    lists:foreach(fun log_stderr_line/1, Lines).

%% @doc Log one Python stderr line unless it is expected startup noise.
log_stderr_line(<<>>) ->
    ok;
log_stderr_line(Line) ->
    case ignore_stderr_line(Line) of
        true ->
            ok;
        false ->
            ?LOG_WARNING(#{
                in => ?MODULE,
                text => <<"Argos Translate Python stderr">>,
                message => Line
            })
    end.

%% @doc Check if a Python stderr line is a known harmless Argos warning.
ignore_stderr_line(Line) ->
    binary:match(Line, <<"package default expects mwt, which has been added">>) =/= nomatch.

%% @doc Stop the Python child process if it has an OS pid.
stop_python(#state{ os_pid = undefined }) ->
    ok;
stop_python(#state{ os_pid = OsPid }) ->
    exec:stop(OsPid),
    ok.
