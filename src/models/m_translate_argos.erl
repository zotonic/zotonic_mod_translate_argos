%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Model for translating texts using Argos Translate.
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

-module(m_translate_argos).

-export([
    m_get/3,
    ensure_python/0,
    install_python/0,
    is_configured/0,
    data_dir/1,
    install_package/2,
    package/2,
    packages/1,
    priv_file/1,
    python_command/0,
    translate/4,
    translate_html/4,
    translate_tags/4,
    timeout/1,
    update_packages/1,
    venv_python/0
    ]).

-include_lib("zotonic_core/include/zotonic.hrl").

-define(DEFAULT_TIMEOUT, 120000).
-define(TRANSLATE_BATCH_SIZE, 16).
-define(DEFAULT_MAX_QUEUE, 100).


%% @doc Expose Argos configuration and package data to templates.
m_get([ <<"is_configured">> | Rest ], _Msg, _Context) ->
    {ok, {is_configured(), Rest}};
m_get([ <<"packages">> | Rest ], _Msg, Context) ->
    case z_acl:is_allowed(use, mod_admin_config, Context) of
        true ->
            case packages(Context) of
                {ok, Packages} ->
                    {ok, {Packages, Rest}};
                {error, _Reason} = Error ->
                    Error
            end;
        false ->
            {error, eacces}
    end;
m_get(_Path, _Msg, _Context) ->
    {error, enoent}.


-spec is_configured() -> boolean().
%% @doc Check if a Python command has been configured.
is_configured() ->
    python_command() =/= <<>>.

-spec install_python() -> ok | {error, Reason} when
    Reason :: term().
%% @doc Create or update the shared virtualenv and install requirements.
install_python() ->
    Requirements = priv_file("python/requirements.txt"),
    case z_python:ensure_venv(python_command(), zotonic_mod_translate_argos) of
        ok ->
            case z_python:venv_python_result(zotonic_mod_translate_argos) of
                {ok, VenvPython} ->
                    z_python:pip_install(VenvPython, Requirements);
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec ensure_python() -> ok | {error, Reason} when
    Reason :: term().
%% @doc Ensure Argos Translate can be imported, installing it if needed.
ensure_python() ->
    case has_argostranslate() of
        true ->
            ok;
        false ->
            install_python()
    end.

-spec translate(SourceLanguage, TargetLanguage, Texts, Context) -> {ok, TranslatedTexts} | {error, Reason} when
    SourceLanguage :: z_language:language() | undefined,
    TargetLanguage :: z_language:language(),
    Texts :: list(binary()),
    Context :: z:context(),
    TranslatedTexts :: list(binary()),
    Reason :: term().
%% @doc Translate plain text binaries from one language to another.
translate(SourceLanguage, TargetLanguage, Texts, Context) when is_list(Texts) ->
    case {language_code(SourceLanguage), language_code(TargetLanguage)} of
        {undefined, _} ->
            {error, source_language};
        {_, undefined} ->
            {error, target_language};
        {SourceCode, TargetCode} ->
            translate_1(SourceCode, TargetCode, Texts, Context)
    end.

%% @doc Call the module worker and normalize a plain text translation response.
translate_1(SourceCode, TargetCode, Texts, Context) ->
    translate_batches(
        fun(Batch) ->
            worker_translate(SourceCode, TargetCode, Batch, Context)
        end,
        SourceCode,
        TargetCode,
        Texts).

%% @doc Call the worker for one batch and normalize a plain text translation response.
translate_batch(WorkerFun, SourceCode, TargetCode, Batch) ->
    Started = log_translate_start(SourceCode, TargetCode, Batch),
    Result = WorkerFun(Batch),
    log_translate_done(SourceCode, TargetCode, Batch, Started, Result),
    case Result of
        {ok, #{ <<"translations">> := Translations }} when is_list(Translations) ->
            {ok, Translations};
        {ok, Response} ->
            ?LOG_ERROR(#{
                in => ?MODULE,
                text => <<"Unexpected result from Argos Translate">>,
                result => error,
                reason => unknown_response,
                response => Response,
                source_language => SourceCode,
                target_language => TargetCode
            }),
            {error, unknown_response};
        {error, Reason} ->
            ?LOG_ERROR(#{
                in => ?MODULE,
                text => <<"Error result from Argos Translate">>,
                result => error,
                reason => Reason,
                source_language => SourceCode,
                target_language => TargetCode
            }),
            {error, Reason}
    end.

-spec translate_tags(SourceLanguage, TargetLanguage, Texts, Context) -> {ok, TranslatedTexts} | {error, Reason} when
    SourceLanguage :: z_language:language() | undefined,
    TargetLanguage :: z_language:language(),
    Texts :: list(binary()),
    Context :: z:context(),
    TranslatedTexts :: list(binary()),
    Reason :: term().
%% @doc Translate tagged text binaries from one language to another.
translate_tags(SourceLanguage, TargetLanguage, Texts, Context) when is_list(Texts) ->
    case {language_code(SourceLanguage), language_code(TargetLanguage)} of
        {undefined, _} ->
            {error, source_language};
        {_, undefined} ->
            {error, target_language};
        {SourceCode, TargetCode} ->
            translate_tags_1(SourceCode, TargetCode, Texts, Context)
    end.

%% @doc Call the module worker and normalize a tagged text translation response.
translate_tags_1(SourceCode, TargetCode, Texts, Context) ->
    translate_batches(
        fun(Batch) ->
            worker_translate_tags(SourceCode, TargetCode, Batch, Context)
        end,
        SourceCode,
        TargetCode,
        Texts).

%% @doc Translate the texts in smaller batches and append results in order.
translate_batches(WorkerFun, SourceCode, TargetCode, Texts) ->
    translate_batches_1(WorkerFun, SourceCode, TargetCode, split_batches(Texts), []).

%% @doc Translate each batch until all work is done or one batch fails.
translate_batches_1(_WorkerFun, _SourceCode, _TargetCode, [], Acc) ->
    {ok, lists:append(lists:reverse(Acc))};
translate_batches_1(WorkerFun, SourceCode, TargetCode, [Batch | Batches], Acc) ->
    case translate_batch(WorkerFun, SourceCode, TargetCode, Batch) of
        {ok, Translations} ->
            translate_batches_1(WorkerFun, SourceCode, TargetCode, Batches, [Translations | Acc]);
        {error, _} = Error ->
            Error
    end.

%% @doc Split a list of texts into bounded batches for the Argos worker.
split_batches(Texts) ->
    split_batches(Texts, ?TRANSLATE_BATCH_SIZE, []).

%% @doc Build text batches using the configured maximum batch size.
split_batches([], _Size, Acc) ->
    lists:reverse(Acc);
split_batches(Texts, Size, Acc) ->
    {Batch, Rest} = take_batch(Texts, Size, []),
    split_batches(Rest, Size, [Batch | Acc]).

%% @doc Take at most Size texts from a list.
take_batch(Rest, 0, Acc) ->
    {lists:reverse(Acc), Rest};
take_batch([], _Size, Acc) ->
    {lists:reverse(Acc), []};
take_batch([Text | Rest], Size, Acc) ->
    take_batch(Rest, Size - 1, [Text | Acc]).

%% @doc Log that a batch of strings is being sent to Argos.
log_translate_start(SourceCode, TargetCode, Batch) ->
    Started = erlang:monotonic_time(millisecond),
    ?LOG_INFO(#{
        in => ?MODULE,
        text => <<"Sending strings to Argos Translate">>,
        count => length(Batch),
        source_language => SourceCode,
        target_language => TargetCode
    }),
    Started.

%% @doc Log the elapsed time for a completed Argos translation request.
log_translate_done(SourceCode, TargetCode, Batch, Started, Result) ->
    ?LOG_INFO(#{
        in => ?MODULE,
        text => <<"Argos Translate finished">>,
        count => length(Batch),
        duration_ms => erlang:monotonic_time(millisecond) - Started,
        result => translate_result(Result),
        source_language => SourceCode,
        target_language => TargetCode
    }).

%% @doc Return a compact log status for a translation response.
translate_result({ok, #{ <<"translations">> := Translations }}) when is_list(Translations) ->
    ok;
translate_result({ok, _Response}) ->
    unexpected_response;
translate_result({error, _Reason}) ->
    error.

-spec translate_html(SourceLanguage, TargetLanguage, Texts, Context) -> {ok, TranslatedTexts} | {error, Reason} when
    SourceLanguage :: z_language:language() | undefined,
    TargetLanguage :: z_language:language(),
    Texts :: list(binary()),
    Context :: z:context(),
    TranslatedTexts :: list(binary()),
    Reason :: term().
%% @doc Translate HTML while preserving block structure and inline tags.
translate_html(SourceLanguage, TargetLanguage, Texts, Context) when is_list(Texts) ->
    case {language_code(SourceLanguage), language_code(TargetLanguage)} of
        {undefined, _} ->
            {error, source_language};
        {_, undefined} ->
            {error, target_language};
        {SourceCode, TargetCode} ->
            translate_argos_html:translate(SourceCode, TargetCode, Texts, Context)
    end.

-spec packages(Context) -> {ok, map()} | {error, Reason} when
    Context :: z:context(),
    Reason :: term().
%% @doc Return normalized package data.
packages(Context) ->
    case worker_packages(Context) of
        {ok, #{ <<"packages">> := Packages }} ->
            {ok, #{
                packages => [ normalize_package(Pkg) || Pkg <- Packages ],
                error => undefined
            }};
        {error, eacces} = Error ->
            Error;
        {error, timeout} = Error ->
            Error;
        {error, Reason} ->
            package_error_result(Reason)
    end.

-spec package_error_result(Reason) -> {ok, map()} when
    Reason :: term().
%% @doc Return a template-friendly package-list error map.
package_error_result(Reason) ->
    {ok, #{
        packages => [],
        error => Reason,
        error_reason => error_reason(Reason),
        error_message => error_message(Reason)
    }}.

%% @doc Return a compact error reason for display.
error_reason(#{ reason := Reason }) ->
    Reason;
error_reason(Reason) ->
    Reason.

%% @doc Return a human-readable error message for display.
error_message(#{ message := Message }) ->
    Message;
error_message(#{ command := Command, reason := Reason }) ->
    format_error_message("Command failed: ~p (~p)", [ Command, Reason ]);
error_message(#{ reason := python_down, detail := Reason }) ->
    format_error_message("Python worker stopped: ~p", [ Reason ]);
error_message(#{ reason := Reason } = Error) ->
    format_error_message("~p: ~p", [ Reason, Error ]);
error_message(Error) when is_map(Error) ->
    format_error_message("~p", [ Error ]);
error_message(overload) ->
    <<"The Argos Translate worker is overloaded.">>;
error_message(argostranslate_import) ->
    <<"The Python argostranslate package could not be imported.">>;
error_message(packages) ->
    <<"Argos Translate could not fetch the package list.">>;
error_message(update_packages) ->
    <<"Argos Translate could not update the package index.">>;
error_message(install_package) ->
    <<"Argos Translate could not install the package.">>;
error_message(python_not_started) ->
    <<"The Argos Translate Python worker could not be started.">>;
error_message(output_too_large) ->
    <<"The Argos Translate Python worker returned too much data.">>;
error_message(invalid_json) ->
    <<"The Argos Translate Python worker returned invalid JSON.">>;
error_message(Reason) ->
    z_convert:to_binary(Reason).

-spec format_error_message(Format, Args) -> binary() when
    Format :: string(),
    Args :: list().
%% @doc Format an error message as Unicode-safe binary text.
format_error_message(Format, Args) ->
    unicode_to_binary(io_lib:format(Format, Args)).

-spec unicode_to_binary(Text) -> binary() when
    Text :: unicode:chardata().
%% @doc Convert Unicode chardata to binary and handle invalid Unicode data.
unicode_to_binary(Text) ->
    case unicode:characters_to_binary(Text) of
        Bin when is_binary(Bin) ->
            Bin;
        {error, Bin, _Rest} ->
            <<Bin/binary, " [invalid unicode data]">>;
        {incomplete, Bin, _Rest} ->
            <<Bin/binary, " [incomplete unicode data]">>
    end.

-spec package(PackageName, Context) -> map() | undefined when
    PackageName :: binary(),
    Context :: z:context().
%% @doc Find one normalized package by package name.
package(PackageName, Context) ->
    case packages(Context) of
        {ok, #{ packages := Packages }} ->
            find_package(PackageName, Packages);
        _ ->
            undefined
    end.

-spec install_package(PackageName, Context) -> {ok, map()} | {error, Reason} when
    PackageName :: binary(),
    Context :: z:context(),
    Reason :: term().
%% @doc Install or update one Argos package via the module worker.
install_package(PackageName, Context) ->
    worker_install_package(PackageName, Context).

%% @doc Refresh the Argos package index in the Python environment.
update_packages(Context) ->
    worker_update_packages(Context).

%% @doc Translate plain text strings using the shared Argos worker.
worker_translate(SourceCode, TargetCode, Texts, Context) ->
    Timeout = timeout(Context),
    case ensure_started(Context) of
        ok ->
            translate_argos_worker:translate(
                name(),
                SourceCode,
                TargetCode,
                Texts,
                Timeout);
        {error, _} = Error ->
            Error
    end.

%% @doc Translate tagged text strings using the shared Argos worker.
worker_translate_tags(SourceCode, TargetCode, Texts, Context) ->
    Timeout = timeout(Context),
    case ensure_started(Context) of
        ok ->
            translate_argos_worker:translate_tags(
                name(),
                SourceCode,
                TargetCode,
                Texts,
                Timeout);
        {error, _} = Error ->
            Error
    end.

%% @doc Fetch available and installed Argos packages from the worker.
worker_packages(Context) ->
    Timeout = timeout(Context),
    case ensure_started(Context) of
        ok ->
            translate_argos_worker:packages(name(), Timeout);
        {error, _} = Error ->
            Error
    end.

%% @doc Install or update one Argos package by package name.
worker_install_package(PackageName, Context) ->
    Timeout = timeout(Context),
    case ensure_started(Context) of
        ok ->
            translate_argos_worker:install_package(name(), PackageName, Timeout);
        {error, _} = Error ->
            Error
    end.

%% @doc Refresh the Argos package index in the Python environment.
worker_update_packages(Context) ->
    Timeout = timeout(Context),
    case ensure_started(Context) of
        ok ->
            translate_argos_worker:update_packages(name(), Timeout);
        {error, _} = Error ->
            Error
    end.

%% @doc Ensure the shared Argos worker has been started.
ensure_started(Context) ->
    Name = name(),
    case whereis(Name) of
        Pid when is_pid(Pid) ->
            ok;
        undefined ->
            ensure_python_started(Name, max_queue(Context))
    end.

%% @doc Install Python if needed and register the worker with the system supervisor.
ensure_python_started(Name, MaxQueue) ->
    case ensure_python() of
        ok ->
            ChildSpec = translate_argos_worker:child_spec(Name, command(), MaxQueue),
            start_worker(Name, ChildSpec);
        {error, _} = Error ->
            Error
    end.

%% @doc Start the worker child and wait briefly if the child spec was just added.
start_worker(Name, ChildSpec) ->
    case z_system_process:start_child(ChildSpec) of
        {ok, _Pid} ->
            ok;
        {ok, _Pid, _Info} ->
            ok;
        {error, {already_started, _Pid}} ->
            ok;
        {error, already_present} ->
            wait_started(Name, 50);
        {error, _} = Error ->
            Error
    end.

%% @doc Poll until the worker process has registered its local name.
wait_started(Name, Retries) when Retries > 0 ->
    case whereis(Name) of
        Pid when is_pid(Pid) ->
            ok;
        undefined ->
            timer:sleep(100),
            wait_started(Name, Retries - 1)
    end;
wait_started(_Name, 0) ->
    {error, not_started}.

%% @doc Build the command used to start the Python worker process.
command() ->
    VenvPython = venv_python(),
    Python = case filelib:is_file(VenvPython) of
        true -> VenvPython;
        false -> python_command()
    end,
    [
        unicode:characters_to_list(Python),
        unicode:characters_to_list(priv_file("python/translate_argos.py")),
        unicode:characters_to_list(data_dir("argos")),
        <<"auto">>
    ].

%% @doc Return the global local name used for the shared Argos worker.
name() ->
    zotonic_translator_argos.

%% @doc Normalize a Zotonic language id to an Argos language code.
language_code(undefined) ->
    undefined;
language_code(<<>>) ->
    undefined;
language_code(<<"x-default">>) ->
    undefined;
language_code(<<"x-none">>) ->
    undefined;
language_code(Language) ->
    Code = z_convert:to_binary(Language),
    case binary:split(Code, <<"-">>) of
        [Primary, _Variant] -> z_string:to_lower(Primary);
        [Primary] -> z_string:to_lower(Primary)
    end.

%% @doc Resolve a file path below this module's priv directory.
priv_file(Path) ->
    filename:join(code:priv_dir(zotonic_mod_translate_argos), Path).

%% @doc Resolve a file path below the shared module data directory.
data_dir(Path) ->
    {ok, Dir} = z_config_files:app_data_dir(zotonic_mod_translate_argos),
    filename:join(Dir, Path).

%% @doc Return the Python executable inside the shared virtualenv.
venv_python() ->
    z_python:venv_python(zotonic_mod_translate_argos).

%% @doc Return the configured Python command, resolving bare executable names.
python_command() ->
    case z_config:get(translate_argos_python_command) of
        undefined -> z_python:python_command();
        Command -> z_python:python_command(Command)
    end.

%% @doc Return the configured translation timeout in milliseconds.
timeout(Context) ->
    case z_convert:to_integer(m_config:get_value(mod_translate_argos, timeout, ?DEFAULT_TIMEOUT, Context)) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?DEFAULT_TIMEOUT
    end.

%% @doc Return the globally configured maximum number of queued worker requests.
max_queue(_Context) ->
    case z_convert:to_integer(z_config:get(translate_argos_max_queue, ?DEFAULT_MAX_QUEUE)) of
        N when is_integer(N), N >= 0 -> N;
        _ -> ?DEFAULT_MAX_QUEUE
    end.

%% @doc Normalize a package map returned by the Python worker.
normalize_package(Pkg) ->
    #{
        name => maps:get(<<"name">>, Pkg, <<>>),
        from_code => maps:get(<<"from_code">>, Pkg, <<>>),
        from_name => maps:get(<<"from_name">>, Pkg, <<>>),
        to_code => maps:get(<<"to_code">>, Pkg, <<>>),
        to_name => maps:get(<<"to_name">>, Pkg, <<>>),
        version => maps:get(<<"version">>, Pkg, <<>>),
        installed_version => maps:get(<<"installed_version">>, Pkg, undefined),
        installed => maps:get(<<"installed">>, Pkg, false),
        outdated => maps:get(<<"outdated">>, Pkg, false)
    }.

%% @doc Find a normalized package map in a list.
find_package(_PackageName, []) ->
    undefined;
find_package(PackageName, [#{ name := PackageName } = Package | _]) ->
    Package;
find_package(PackageName, [_ | Packages]) ->
    find_package(PackageName, Packages).

%% @doc Check if the virtualenv can import the required Argos modules.
has_argostranslate() ->
    VenvPython = venv_python(),
    case filelib:is_file(VenvPython) of
        true ->
            Command = [
                VenvPython,
                "-c",
                "import argostranslate.package, argostranslate.tags, argostranslate.translate"
            ],
            z_python:run_install_command(Command) =:= ok;
        false ->
            false
    end.
