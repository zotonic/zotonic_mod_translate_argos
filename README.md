# zotonic_mod_translate_argos

Automatic translation of texts using [Argos Translate](https://github.com/argosopentech/argos-translate).

If this module is enabled then the _translate_ option will be added to the dialog shown when
adding a language. This allows translating texts from an existing language to another language.

## Architecture

The Argos translator is a single worker shared between all sites. The worker is not started
when Zotonic starts. Instead, the model starts it on demand when the first translation or
package request is made.

The worker is added to the global Zotonic system-process supervisor via `z_system_process`.
The module supplies the child spec for `translate_argos_worker`, and the supervisor keeps that
Erlang worker running independently of any individual site.

`translate_argos_worker` starts one long-running Python child process using `erlexec`. The
Erlang worker communicates with Python over stdin/stdout using newline-delimited JSON. The
Python process loads Argos Translate and performs the actual package administration and text
translation work. No HTTP endpoint or external service is started.

The worker serializes all Python requests. If a request arrives while Python is busy, the
request is queued up to `translate_argos_max_queue` items across all sites. Package
administration commands (`packages`, `install_package`, and `update_packages`) are queued in a
priority queue and are handled before queued translation requests. Translation requests are
queued at the back of the normal FIFO queue.

Queued requests are monitored. If the caller process exits before its request is started, the
request is removed. If a queued request has already passed the caller's `gen_server:call`
timeout window, it is skipped instead of being sent to Python.

## Runtime configuration

On install, the module creates a Python virtual environment in the Zotonic data directory under
`apps/zotonic_mod_translate_argos/venv` and installs `priv/python/requirements.txt`.

When the module starts, it starts a long-running Python worker process from this virtual
environment. The module communicates with the worker over stdin/stdout using newline-delimited
JSON. No separate HTTP service is needed.

Configuration keys:

* `translate_argos_python_command` Zotonic system config for the Python executable used to create the virtual environment. Defaults to `python3`; bare command names are resolved with `os:find_executable/1` before starting Python.
* `translate_argos_max_queue` Zotonic system config for the maximum number of queued requests in the shared Argos worker. Defaults to `100` if not set. Set this in `zotonic.config`, for example: `{translate_argos_max_queue, 100}`.
* `mod_translate_argos.timeout` Maximum runtime per translation request in milliseconds. Defaults to `120000`.

## Argos packages

Argos only translates language pairs for which packages are installed. For example:

```sh
<zotonic-data-dir>/apps/zotonic_mod_translate_argos/venv/bin/argospm update
<zotonic-data-dir>/apps/zotonic_mod_translate_argos/venv/bin/argospm install translate-en_nl
```

Argos can also pivot through intermediate languages if the required packages are installed.

## ACL configuration

You must allow users to use the Argos integration. Add `use.mod_translate_argos` for the
user groups that are allowed to translate using Argos.
