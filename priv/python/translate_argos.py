#!/usr/bin/env python3
"""Long-running Argos Translate worker for Zotonic.

Protocol:
    stdin:  one JSON request per line
    stdout: one JSON response per line

Request:
    {"id": 1, "from": "en", "to": "nl", "texts": ["Hello"]}

Response:
    {"id": 1, "translations": ["Hallo"]}
    {"id": 1, "error": "language_pair"}
"""

from __future__ import annotations

import json
import os
import sys
import traceback
from html import escape
from html.parser import HTMLParser
from typing import Any

if len(sys.argv) > 1:
    argos_data_dir = sys.argv[1]
    os.environ.setdefault("XDG_DATA_HOME", os.path.join(argos_data_dir, "data"))
    os.environ.setdefault("XDG_CONFIG_HOME", os.path.join(argos_data_dir, "config"))
    os.environ.setdefault("XDG_CACHE_HOME", os.path.join(argos_data_dir, "cache"))
    os.environ.setdefault("ARGOS_PACKAGES_DIR", os.path.join(argos_data_dir, "packages"))

try:
    import argostranslate.package
    import argostranslate.tags
    import argostranslate.translate
except Exception:
    traceback.print_exc(file=sys.stderr)
    argostranslate = None


class HtmlTag(argostranslate.tags.Tag if argostranslate is not None else object):
    def __init__(self, name: str, children: list[Any], self_closing: bool = False):
        super().__init__(children)
        self.name = name
        self.self_closing = self_closing


class TagParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.root = HtmlTag("", [])
        self.stack = [self.root]

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        child = HtmlTag(tag, [])
        self.stack[-1].children.append(child)
        self.stack.append(child)

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.stack[-1].children.append(HtmlTag(tag, [], True))

    def handle_endtag(self, tag: str) -> None:
        if len(self.stack) > 1 and self.stack[-1].name == tag:
            self.stack.pop()

    def handle_data(self, data: str) -> None:
        if data:
            self.stack[-1].children.append(data)


def main() -> int:
    translations: dict[tuple[str, str], Any] = {}

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        request: Any = None
        try:
            request = json.loads(line)
            response = handle_request(request, translations)
        except Exception:
            traceback.print_exc(file=sys.stderr)
            request_id = request.get("id") if isinstance(request, dict) else None
            response = {"id": request_id, "error": "translation"}

        write_json(response)

    return 0


def handle_request(
    request: dict[str, Any],
    translations: dict[tuple[str, str], Any],
) -> dict[str, Any]:
    request_id = request.get("id")
    op = request.get("op", "translate")

    if op == "packages":
        return list_packages(request_id)
    if op == "install_package":
        return install_package(request_id, request.get("name"))
    if op == "update_packages":
        return update_packages(request_id)
    if op != "translate":
        return {"id": request_id, "error": "invalid_op"}

    source_code = request.get("from")
    target_code = request.get("to")
    texts = request.get("texts")
    preserve_tags = request.get("tags") is True

    if argostranslate is None:
        return {"id": request_id, "error": "argostranslate_import"}

    if not isinstance(request_id, int):
        return {"id": request_id, "error": "invalid_id"}
    if not isinstance(source_code, str) or not isinstance(target_code, str):
        return {"id": request_id, "error": "invalid_language"}
    if not isinstance(texts, list) or not all(isinstance(text, str) for text in texts):
        return {"id": request_id, "error": "invalid_texts"}

    translation = get_translation(source_code, target_code, translations)
    if translation is None:
        return {"id": request_id, "error": "language_pair"}

    return {
        "id": request_id,
        "translations": [
            translate_text(translation, text, preserve_tags)
            for text in texts
        ],
    }


def translate_text(translation: Any, text: str, preserve_tags: bool) -> str:
    if preserve_tags:
        return translate_tagged_text(translation, text)
    return translation.translate(text)


def translate_tagged_text(translation: Any, text: str) -> str:
    parser = TagParser()
    parser.feed(text)
    parser.close()
    translate_tag_children(translation, parser.root)
    return render_tag_children(parser.root.children)


def translate_tag_children(translation: Any, tag: HtmlTag) -> None:
    translated_children = []
    for child in tag.children:
        if isinstance(child, str):
            translated_children.append(
                argostranslate.tags.translate_preserve_formatting(translation, child)
            )
        else:
            translate_tag_children(translation, child)
            translated_children.append(child)
    tag.children = translated_children


def render_tag_children(children: list[Any]) -> str:
    return "".join(render_tag_child(child) for child in children)


def render_tag_child(child: Any) -> str:
    if isinstance(child, str):
        return escape(child, quote=False)
    if child.self_closing:
        return f"<{child.name}/>"
    return f"<{child.name}>{render_tag_children(child.children)}</{child.name}>"


def list_packages(request_id: int | None) -> dict[str, Any]:
    if argostranslate is None:
        return {"id": request_id, "error": "argostranslate_import"}

    try:
        installed_versions = {
            argostranslate.package.argospm_package_name(pkg): pkg.package_version
            for pkg in argostranslate.package.get_installed_packages()
        }
        packages = []
        for pkg in argostranslate.package.get_available_packages():
            if pkg.type != "translate" or not pkg.from_code or not pkg.to_code:
                continue
            name = argostranslate.package.argospm_package_name(pkg)
            installed_version = installed_versions.get(name)
            packages.append(
                {
                    "name": name,
                    "from_code": pkg.from_code,
                    "from_name": pkg.from_name,
                    "to_code": pkg.to_code,
                    "to_name": pkg.to_name,
                    "version": pkg.package_version,
                    "installed_version": installed_version,
                    "installed": installed_version is not None,
                    "outdated": (
                        installed_version is not None
                        and installed_version != pkg.package_version
                    ),
                }
            )
        packages.sort(key=lambda pkg: (pkg["from_name"], pkg["to_name"], pkg["name"]))
        return {"id": request_id, "packages": packages}
    except Exception:
        traceback.print_exc(file=sys.stderr)
        return {"id": request_id, "error": "packages"}


def update_packages(request_id: int | None) -> dict[str, Any]:
    if argostranslate is None:
        return {"id": request_id, "error": "argostranslate_import"}

    try:
        argostranslate.package.update_package_index()
        return {"id": request_id, "updated": True}
    except Exception:
        traceback.print_exc(file=sys.stderr)
        return {"id": request_id, "error": "update_packages"}


def install_package(request_id: int | None, package_name: Any) -> dict[str, Any]:
    if argostranslate is None:
        return {"id": request_id, "error": "argostranslate_import"}
    if not isinstance(package_name, str) or not package_name:
        return {"id": request_id, "error": "invalid_package"}

    try:
        for pkg in argostranslate.package.get_available_packages():
            name = argostranslate.package.argospm_package_name(pkg)
            if name == package_name:
                pkg.install()
                return {"id": request_id, "installed": True, "name": name}
        return {"id": request_id, "error": "package_not_found"}
    except Exception:
        traceback.print_exc(file=sys.stderr)
        return {"id": request_id, "error": "install_package"}


def get_translation(
    source_code: str,
    target_code: str,
    translations: dict[tuple[str, str], Any],
) -> Any | None:
    key = (source_code, target_code)
    if key in translations:
        return translations[key]

    try:
        translation = argostranslate.translate.get_translation_from_codes(
            source_code,
            target_code,
        )
    except Exception:
        traceback.print_exc(file=sys.stderr)
        return None

    translations[key] = translation
    return translation


def write_json(data: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(data, ensure_ascii=False))
    sys.stdout.write("\n")
    sys.stdout.flush()


if __name__ == "__main__":
    raise SystemExit(main())
