%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Translation service using Argos Translate.
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

-module(mod_translate_argos).
-moduledoc(#{
    zotonic_keywords => [
        "reference", "content_editor", "module", "localization_and_translation",
        "translated_text", "language_code", "api_and_integration", "configuration",
        "authorization_and_access_control"
    ]
}).
-moduledoc("
Provides automatic translation using a local Argos Translate Python worker as
a translation service for Zotonic's `mod_translation` module.

## Setup and configuration

Enable `mod_translate_argos`. Installation creates a shared Python virtual
environment under `apps/zotonic_mod_translate_argos/venv` in the Zotonic data
directory and installs `priv/python/requirements.txt`. Open **System →
Argos Translate** in the admin to refresh the package index and install the
language packages needed for translation. Package administration requires
`use.mod_admin_config` permission.

Grant `use.mod_translate_argos` to user groups allowed to request translations.
The integration handles the `translate` notification used by the admin's
add-language dialog. Plain text and HTML requests are routed to their matching
model functions. The observer returns `{ok, TranslatedTexts}` on success and
`undefined` on denied access or translation errors, allowing other providers
to handle the notification.

Both source and target languages are required. Language variants are normalized
to their primary language code. Translation runs locally; package installation
and index updates may need network access.

`mod_translate_argos.timeout` sets the worker request timeout in milliseconds;
the default is `120000`. The following are Zotonic system configuration keys:

* `translate_argos_python_command`: override the Python executable used to
  create the virtual environment. Otherwise Zotonic's `python_command` system
  setting is used, falling back to `python3`. Bare command names are resolved
  with `os:find_executable/1`.
* `translate_argos_max_queue`: maximum queued requests across all sites,
  default `100`. Zero disables waiting behind an active request.

Set system configuration in `zotonic.config`, for example:

```erlang
{translate_argos_max_queue, 100}
```

## Language packages

Argos needs installed translation packages for the requested language pair.
Packages can be managed in the admin or with `argospm` from the module's virtual
environment. For example, install an English-to-Dutch package with:

```sh
<zotonic-data-dir>/apps/zotonic_mod_translate_argos/venv/bin/argospm update
<zotonic-data-dir>/apps/zotonic_mod_translate_argos/venv/bin/argospm install translate-en_nl
```

Replace `<zotonic-data-dir>` with the actual Zotonic data directory. Argos can
also translate through intermediate languages when the required packages are
installed. The virtual environment, worker, and language packages are shared
between sites.

## Shared worker

The model starts the worker on demand under `z_system_process`. One persistent
Python process serves all sites and serializes requests. Package administration
has priority over queued translations. Plain and tagged text are sent in batches
of at most 16 strings, retaining the input order.

The worker is started lazily on the first translation or package request, not
at Zotonic startup. The global supervisor keeps it running independently of
individual sites. It launches Python using `erlexec` and exchanges
newline-delimited JSON over stdin/stdout; no separate HTTP service is needed.

Package commands (`packages`, `install_package`, and `update_packages`) use a
priority queue. Translations use a normal FIFO queue. Queued requests are
removed when their caller exits and skipped when their caller's
`gen_server:call` timeout window has already elapsed.

## GPU and Apple Accelerate support

Argos uses CTranslate2 for model inference. The module passes `auto` as the
worker's device setting; the Python script uses it for `ARGOS_DEVICE_TYPE`
unless that environment variable is already set. Acceleration depends on the
installed CTranslate2 build and the available hardware and runtime libraries.
With automatic device selection, CPU is the fallback when a supported GPU
backend is unavailable.

### NVIDIA CUDA

CUDA acceleration requires a supported NVIDIA GPU, NVIDIA driver, CUDA runtime,
and a CTranslate2 build with CUDA support. For a custom source build, the
README uses these CMake options from the CTranslate2 build directory:

```sh
cmake .. -DWITH_CUDA=ON -DWITH_CUDNN=ON
make -j
make install
```

Build the matching CTranslate2 Python wheel and install it into the Argos
virtual environment. When using a custom installation prefix, ensure that the
Python build and runtime can find the CTranslate2 headers and shared libraries.

### macOS and Apple Accelerate

Modern Apple hardware does not provide the NVIDIA CUDA path. CTranslate2 can
use Apple Accelerate for CPU math and linear algebra when its installed wheel
or source build enables that backend. This is CPU acceleration, not Apple GPU,
Metal, or MPS execution.

For a custom source build, the README uses:

```sh
cmake .. -DWITH_ACCELERATE=ON
make -j
make install
```

Build and install the matching Python wheel into the module virtual environment.

### Installing a custom inference build

The module's Python requirements normally determine which CTranslate2 build is
installed. After the virtual environment exists, install a custom wheel with:

```sh
<zotonic-data-dir>/apps/zotonic_mod_translate_argos/venv/bin/pip install /path/to/ctranslate2-*.whl
```

Restart Zotonic, or stop the shared Argos worker so it restarts with the new
Python package. Because the worker is shared, this affects every site using it.
").

-mod_title("Translate with Argos").
-mod_description("Translation service using Argos Translate.").
-mod_author("Marc Worrell <marc@worrell.nl>").
-mod_depends([ mod_translation ]).
-mod_schema(1).
-mod_config([
        #{
            key => timeout,
            type => integer,
            default => 120000,
            description => "Maximum translation runtime in milliseconds."
        }
    ]).

-author("Marc Worrell <marc@worrell.nl>").

-export([
    event/2,
    manage_data/2,
    manage_schema/2,
    observe_translate/2,
    observe_admin_menu/3
    ]).

-include_lib("zotonic_core/include/zotonic.hrl").
-include_lib("zotonic_mod_admin/include/admin_menu.hrl").

%% @doc No schema changes are needed for this module.
manage_schema(_Version, _Context) ->
    ok.

%% @doc Install the shared Python dependencies when the module is installed.
manage_data(_Version, _Context) ->
    case m_translate_argos:install_python() of
        ok ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR(#{
                in => ?MODULE,
                text => <<"Could not install Argos Translate Python dependencies">>,
                result => error,
                reason => Reason
            }),
            ok
    end.

%% @doc Handle translation notifications from mod_translation.
observe_translate(#translate{
        type = Type,
        from = From,
        to = To,
        texts = Texts
    }, Context) ->
    case z_acl:is_allowed(use, ?MODULE, Context) of
        true ->
            case translate_texts(Type, From, To, Texts, Context) of
                {ok, _} = Ok ->
                    Ok;
                {error, _} ->
                    undefined
            end;
        false ->
            ?LOG_INFO(#{
                in => ?MODULE,
                text => <<"Not allowed to use Argos Translate for translations">>,
                result => error,
                reason => eacces
            }),
            undefined
    end.

%% @doc Dispatch text and HTML translation to the matching model function.
translate_texts(html, From, To, Texts, Context) ->
    m_translate_argos:translate_html(From, To, Texts, Context);
translate_texts(_Type, From, To, Texts, Context) ->
    m_translate_argos:translate(From, To, Texts, Context).

%% @doc Add the Argos Translate configuration page to the admin menu.
observe_admin_menu(#admin_menu{}, Acc, Context) ->
    [
        #menu_item{
            id = admin_translate_argos,
            parent = admin_system,
            label = ?__("Argos Translate", Context),
            url = {admin_translate_argos},
            visiblecheck = {acl, use, mod_admin_config}
        }
        | Acc
    ].

%% @doc Handle admin postbacks for loading, installing, and updating packages.
event(#postback{message = {argos_install_package, Args}}, Context) ->
    case z_acl:is_allowed(use, mod_admin_config, Context) of
        true ->
            PackageName = z_convert:to_binary(proplists:get_value(name, Args, <<>>)),
            Target = z_convert:to_binary(proplists:get_value(target, Args, <<>>)),
            case m_translate_argos:install_package(PackageName, Context) of
                {ok, _} ->
                    Context1 = z_render:growl(?__("Installed Argos Translate package.", Context), Context),
                    update_package_row(PackageName, Target, Context1);
                {error, Reason} ->
                    Context1 = z_render:growl_error(format_error(Reason, Context), Context),
                    z_render:wire({unmask, [{target, Target}]}, Context1)
            end;
        false ->
            z_render:growl_error(?__("You are not allowed to configure Argos Translate.", Context), Context)
    end;
event(#postback{message = {argos_load_packages, Args}}, Context) ->
    Target = z_convert:to_binary(proplists:get_value(target, Args, <<>>)),
    case z_acl:is_allowed(use, mod_admin_config, Context) of
        true ->
            update_packages_list(Target, Context);
        false ->
            z_render:growl_error(?__("You are not allowed to configure Argos Translate.", Context), Context)
    end;
event(#postback{message = {argos_update_packages, Args}}, Context) ->
    Target = z_convert:to_binary(proplists:get_value(target, Args, <<>>)),
    case z_acl:is_allowed(use, mod_admin_config, Context) of
        true ->
            case m_translate_argos:update_packages(Context) of
                {ok, _} ->
                    Context1 = z_render:growl(?__("Updated the Argos Translate package index.", Context), Context),
                    update_packages_list(Target, Context1);
                {error, Reason} ->
                    Context1 = z_render:growl_error(format_error(Reason, Context), Context),
                    z_render:wire({unmask, [{target, Target}]}, Context1)
            end;
        false ->
            z_render:growl_error(?__("You are not allowed to configure Argos Translate.", Context), Context)
    end.

%% @doc Re-render one package row after an install or update.
update_package_row(_PackageName, <<>>, Context) ->
    Context;
update_package_row(PackageName, Target, Context) ->
    case m_translate_argos:package(PackageName, Context) of
        undefined ->
            Context;
        Package ->
            z_render:update(
                Target,
                #render{
                    template = "_admin_translate_argos_package.tpl",
                    vars = [
                        {p, Package},
                        {row_id, Target}
                    ]
                },
                Context)
    end.

%% @doc Lazily render the package list into the admin page.
update_packages_list(<<>>, Context) ->
    Context;
update_packages_list(Target, Context) ->
    z_render:update(
        Target,
        #render{
            template = "_admin_translate_argos_packages.tpl"
        },
        Context).

%% @doc Format a worker error as escaped admin UI text.
format_error(Reason, Context) ->
    [
        ?__("Argos Translate returned an error:", Context),
        " ",
        z_html:escape(z_convert:to_binary(Reason))
    ].
