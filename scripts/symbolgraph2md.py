#!/usr/bin/env python3
"""Renders a Swift symbol graph (.symbols.json) as a Markdown API reference.

Only public/open symbols are included. Output is deterministic (types and
members sorted by name) so CI can regenerate and diff it to prove the
committed docs match the code.

Usage: symbolgraph2md.py <module.symbols.json> <module-name> > out.md
"""

import json
import sys
from collections import defaultdict

CONTAINER_KINDS = {
    "swift.class": "class",
    "swift.struct": "struct",
    "swift.enum": "enum",
    "swift.protocol": "protocol",
}

KIND_TITLES = {
    "swift.func": "function",
    "swift.method": "method",
    "swift.property": "property",
    "swift.init": "initializer",
    "swift.enum.case": "case",
    "swift.typealias": "typealias",
}


def declaration(symbol):
    """The declaration line, e.g. `public static func normalize(_:) -> String`."""
    fragments = symbol.get("declarationFragments", [])
    return "".join(f.get("spelling", "") for f in fragments).strip()


def doc_comment(symbol):
    lines = symbol.get("docComment", {}).get("lines", [])
    return "\n".join(line.get("text", "") for line in lines).strip()


def title_of(symbol):
    path = symbol.get("pathComponents", [])
    name = path[-1] if path else symbol.get("names", {}).get("title", "?")
    # (To) disambiguate overloaded members and make anchors stable.
    kind = symbol.get("identifier", {}).get("interfaceLanguage", "")
    del kind
    return name


def kind_label(symbol):
    kind = symbol.get("kind", {}).get("identifier", "")
    return KIND_TITLES.get(kind, kind.removeprefix("swift."))


def render_symbol(symbol, level, out):
    name = title_of(symbol)
    out.append(f"{'#' * level} `{name}`\n")
    label = kind_label(symbol)
    out.append(f"_{label}_\n")
    decl = declaration(symbol)
    if decl:
        out.append(f"```swift\n{decl}\n```\n")
    doc = doc_comment(symbol)
    if doc:
        out.append(doc + "\n")


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    graph_path, module = sys.argv[1], sys.argv[2]

    with open(graph_path) as handle:
        graph = json.load(handle)

    symbols = {}
    for symbol in graph.get("symbols", []):
        if symbol.get("accessLevel") in ("public", "open"):
            symbols[symbol["identifier"]["precise"]] = symbol

    member_of = {}
    for rel in graph.get("relationships", []):
        if rel.get("kind") == "memberOf":
            member_of[rel["source"]] = rel["target"]

    children = defaultdict(list)
    roots = []
    external_members = defaultdict(list)
    for precise, symbol in symbols.items():
        parent = member_of.get(precise)
        if parent in symbols:
            children[parent].append(symbol)
        elif parent is None:
            roots.append(symbol)
        else:
            # Member of a type outside the module (e.g. extension String).
            group = symbol.get("pathComponents", ["?"])[0]
            external_members[group].append(symbol)

    def sort_key(symbol):
        return (symbol.get("kind", {}).get("identifier", ""), title_of(symbol))

    out = [
        f"# {module} — public API\n",
        "Generated from the compiler's symbol graph by"
        " `scripts/generate-api-docs.sh`. Do not edit by hand; CI regenerates"
        " this file and fails the build when it drifts from the code.\n",
    ]

    containers = [s for s in roots if s["kind"]["identifier"] in CONTAINER_KINDS]
    freestanding = [s for s in roots if s["kind"]["identifier"] not in CONTAINER_KINDS]

    for container in sorted(containers, key=title_of):
        render_symbol(container, 2, out)
        members = sorted(children[container["identifier"]["precise"]], key=sort_key)
        if members:
            out.append("**Members:**\n")
            for member in members:
                render_symbol(member, 3, out)
        out.append("")

    if freestanding:
        out.append("## Freestanding symbols\n")
        for symbol in sorted(freestanding, key=sort_key):
            render_symbol(symbol, 3, out)

    if external_members:
        out.append("## Extensions of external types\n")
        for group in sorted(external_members):
            out.append(f"### `{group}`\n")
            for member in sorted(external_members[group], key=sort_key):
                decl = declaration(member)
                doc = doc_comment(symbol=member)
                line = f"- `{title_of(member)}` — `{decl}`"
                out.append(line)
                if doc:
                    out.append(f"  {doc.splitlines()[0]}")
            out.append("")

    print("\n".join(out).rstrip() + "\n")


if __name__ == "__main__":
    main()
