#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Translation rebuild script for zh_CN / zh_TW

Rebuilds locale/zh_CN.po and locale/zh_TW.po from the latest .pot; every other
language is out of scope. msgid is taken byte-for-byte from the .pot; msgstr reuses
the previous translation (renamed to *_old.po) and is left empty where none exists.
Per-language headers come from LANG_NAME, the msgstr[n] slot count from NPLURALS,
and Last-Translator from the previous file — a field the rebuild inherits rather
than invents, so an old header without it simply grows no such line.

The plugin root is found by walking up from this script, so the script may sit at
any depth inside the plugin; an explicit path argument overrides the search.

Steps:
  1. Rename the two *.po to *_old.po (abort if any *_old.po already exists).
  2. Drop the .pot's repeated location comments (a line calling _() twice for the
     same string yields the same file:line twice); a shared location is one location
     for gettext, so the first occurrence is kept and the rest removed.
  3. Rebuild entries from the .pot, reusing old translations and the field layout
     verbatim (the script never re-wraps). A msgid the .pot no longer carries
     keeps its translation as a #~ entry at the end, sorted by msgid; the #~
     entries already there are kept, silently. Live entries win over a #~ copy of
     the same msgid, and a #~ entry is read only for a msgid no live entry
     carries. fuzzy is a review marker inherited from any reused entry; a msgid
     whose plural shape changed starts empty.
  4. Run the reuse check in memory: no old translation may be dropped. If it
     fails, nothing is written. An entry left with no translation is flagged
     #, fuzzy so a reviewer can see the gap.
  5. Only once both languages pass are the real .po files atomically replaced
     and the *_old.po files deleted: until then the .po files stay in place as
     *_old.po, so the runtime never loses its language files. A failed check or
     a crash renames *_old.po back to *.po and drops the tmp files.

"""

import os
import re
import sys
import time
from pathlib import Path
from typing import NamedTuple


def find_plugin_root(start):
    # Walk up from start until a plugin root turns up, so this script works from
    # any directory inside the plugin (locale/, scripts/, the root itself). The
    # .koplugin suffix wins; _meta.lua is only a fallback for a checkout whose
    # directory lost the suffix.
    fallback = None
    for d in [start, *start.parents]:
        if d.name.endswith(".koplugin"):
            return d
        if fallback is None and (d / "_meta.lua").is_file():
            fallback = d
    return fallback


def _check_plugin_root(root):
    # A root carrying neither marker would silently treat a parent directory as the
    # plugin and fail much later with a confusing "no .pot file found" message.
    if not (root.name.endswith(".koplugin") or (root / "_meta.lua").is_file()):
        print(f"Error: {root} is not a plugin directory "
              f"(no *.koplugin name suffix and no _meta.lua)")
        sys.exit(1)
    return root


def plugin_root(argv):
    # The optional first argument wins; otherwise the nearest root above this script.
    if argv:
        return _check_plugin_root(Path(argv[0]).expanduser().resolve())
    found = find_plugin_root(Path(__file__).resolve().parent)
    if found is None:
        print(f"Error: no plugin directory found at or above {Path(__file__).resolve().parent}")
        print("Move this script into the plugin, or pass the plugin directory as an argument.")
        sys.exit(1)
    return found


# `fullname = "value"` in _meta.lua, optionally wrapped in the Lua _() translate
# call. Two capture groups, one per quote style, so a value may contain the other
# quote character.
_FULLNAME_RE = re.compile(
    r'^\s*fullname\s*=\s*(?:_\s*\(\s*)?'
    r'(?:"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\')',
    re.MULTILINE)


def find_pot(root):
    # Locate the plugin's single .pot file; its parent directory is the translation
    # directory, so no directory name (locale/, locales/, l10n/, ...) is assumed.
    found = [
        p for p in root.rglob("*.pot")
        if not any(part.startswith(".") for part in p.relative_to(root).parts)
    ]
    if not found:
        print(f"Error: no .pot file found under {root}")
        sys.exit(1)
    if len(found) > 1:
        print(f"Error: found {len(found)} .pot files under {root}, expected exactly one:")
        for p in sorted(found):
            print(f"  - {p.relative_to(root)}")
        print("Keep only the .pot of this plugin and rerun.")
        sys.exit(1)
    return found[0]


def _meta_value(root, pattern):
    # Read one string field out of _meta.lua; None when the field is absent. Only
    # `is not None`, never truthiness, tells an empty value from a missing group.
    meta = root / "_meta.lua"
    if not meta.exists():
        print(f"Error: _meta.lua not found: {meta}")
        sys.exit(1)
    m = pattern.search(meta.read_text(encoding="utf-8-sig"))
    if m is None:
        return None
    return m.group(1) if m.group(1) is not None else m.group(2)


def plugin_fullname(root):
    # Read the plugin's displayed name from _meta.lua, with or without the _() wrapper.
    name = _meta_value(root, _FULLNAME_RE)
    if name is None:
        print(f"Error: no fullname found in {root / '_meta.lua'}")
        sys.exit(1)
    return name


class Layout(NamedTuple):
    # What the rebuild derives from the plugin tree; built by resolve_paths() so
    # importing this module touches no file.
    pot_file:   Path
    locale_dir: Path
    fullname:   str
    project_id: str


def resolve_paths(root):
    # A missing piece aborts the run instead of the import.
    root = Path(root)
    pot_file = find_pot(root)
    if pot_file.parent == root:
        print(f"Error: {pot_file.name} must sit in a subdirectory (e.g. locale/), not in the plugin root")
        sys.exit(1)
    # Project-Id-Version stays bare, matching the .pot: a version there would
    # disagree with the template and rewrite this header line on every run.
    fullname = plugin_fullname(root)
    return Layout(pot_file, pot_file.parent, fullname, project_id(fullname))


# The two locales this script maintains. Both are single-form languages.
LANG_NAME = {
    'zh_CN': 'Chinese (Simplified)',
    'zh_TW': 'Chinese (Traditional)',
}
PLURAL_FORMS = "nplurals=1; plural=0;"
NPLURALS = 1


def old_po_path(locale_dir, code):
    return locale_dir / f"{code}_old.po"

def new_po_path(locale_dir, code):
    return locale_dir / f"{code}.po"

def tmp_po_path(locale_dir, code):
    # Written first, then atomically replaced via os.replace once the checks pass.
    return locale_dir / f"{code}.po.tmp"


# GNU gettext collapses \xNN, \NNN, \n … back to single bytes, so `…` and
# `\xe2\x80\xa6` are the same msgid. match_key() removes that difference so both
# spellings hit the same old translation; escapes affect the comparison key only,
# never the output.
_SIMPLE_ESCAPES = {
    "n": b"\n", "t": b"\t", "r": b"\r", "b": b"\b", "f": b"\f",
    "v": b"\v", "a": b"\a", "\\": b"\\", '"': b'"',
}
_HEX_DIGITS = "0123456789abcdefABCDEF"
_OCT_DIGITS = "01234567"


def decode_po_escapes(s: str):
    # Decode the escape sequences of a gettext literal into bytes (the only decoder here).
    # Must be single-pass: folding backslashes first loses whether a backslash itself
    # was escaped, turning a literal \\xNN into \xNN.
    out = bytearray()
    i, n = 0, len(s)
    while i < n:
        ch = s[i]
        if ch != "\\" or i + 1 >= n:
            out.extend(ch.encode("utf-8"))
            i += 1
            continue
        nxt = s[i + 1]
        if nxt == "x":
            j, digits = i + 2, ""
            while j < n and len(digits) < 2 and s[j] in _HEX_DIGITS:
                digits += s[j]
                j += 1
            if digits:
                out.append(int(digits, 16))
                i = j
            else:
                out.extend(b"\\x")  # \x with no digits: keep it literal
                i += 2
            continue
        if nxt in _OCT_DIGITS:
            j, digits = i + 1, ""
            while j < n and len(digits) < 3 and s[j] in _OCT_DIGITS:
                digits += s[j]
                j += 1
            out.append(int(digits, 8) & 0xFF)
            i = j
            continue
        out.extend(_SIMPLE_ESCAPES.get(nxt, ("\\" + nxt).encode("utf-8")))
        i += 2
    return bytes(out)


def match_key(s):
    # Return the comparison key of a msgid (old-translation reuse keys on this).
    # Invalid bytes map to distinct surrogates, so two different literals never collide.
    if not s:
        return s
    return decode_po_escapes(s).decode("utf-8", "surrogateescape")


def split_blocks(text):
    # Split .pot/.po text into entry blocks on blank lines.
    blocks, current = [], []
    for line in text.split("\n"):
        if line.strip() == "":
            if current:
                blocks.append(current)
                current = []
        else:
            current.append(line)
    if current:
        blocks.append(current)
    return blocks


# msgid_plural is listed before msgid so the longer name wins; a plain msgstr has no
# index. A line with a field name opens that field, one without continues it. The
# leading \s* also matches indented field lines, which must not be dropped.
_FIELD_RE = re.compile(r'^\s*(?:(msgid_plural|msgid|msgstr(?:\[(\d+)\])?)\s+)?"(.*)"\s*$')


def is_fuzzy_flag_line(line):
    # True for a `#,` flag line carrying fuzzy. A flag list may hold several flags
    # (`#, fuzzy, c-format`), so each one is compared as a whole word.
    if not line.startswith("#,"):
        return False
    return "fuzzy" in [flag.strip() for flag in line[2:].split(",")]


def parse_fields(block):
    # Read the msgid / msgid_plural / msgstr fields of a block; continuation lines
    # append to the field currently being read. Every field keeps its physical
    # lines, because the output reuses the source layout instead of re-wrapping.
    msgid = msgid_plural = None
    msgstrs = {}
    target = None  # field list accepting continuation lines
    for line in block:
        m = _FIELD_RE.match(line)
        if m is None:
            # A comment ends the field being read, so a line after it cannot be
            # mistaken for a continuation of that field.
            if line.startswith("#"):
                target = None
            continue  # anything else is ignored (blank lines never enter a block)
        # Continuation: each line is stored as its own literal, never re-escaped.
        name, idx, content = m.group(1), m.group(2), m.group(3)
        if name is None:
            if target is not None:
                target.append(content)
        elif name == "msgid":
            msgid = target = [content]
        elif name == "msgid_plural":
            msgid_plural = target = [content]
        else:  # msgstr / msgstr[n]; a plain msgstr is index 0
            target = [content]
            msgstrs[int(idx) if idx is not None else 0] = target
    return msgid, msgid_plural, msgstrs


def parse_entry_block(block):
    # Parse one entry block into a dict: comments and locations first, then the fields.
    entry = {
        "occurrences":   [],   # [raw location string after "#: ", ...]
        "comment_lines": [],   # comment lines starting with #
        "msgid":         None, # [line content, ...]; None when the block has no msgid
        "msgid_plural":  None,
        "msgstrs":       {},   # {plural index: [line content, ...]}
        "fuzzy":         False, # True when the block carries a `#, fuzzy` flag line
    }
    for line in block:
        if line.startswith("#:"):
            entry["occurrences"].append(line[2:].strip())
        elif line.startswith("#"):
            entry["comment_lines"].append(line)
            if is_fuzzy_flag_line(line):
                entry["fuzzy"] = True
    entry["msgid"], entry["msgid_plural"], entry["msgstrs"] = parse_fields(block)
    return entry


def parse_obsolete_block(block):
    # Strip gettext's obsolete prefix and reuse the ordinary reader, so a #~
    # translation keeps its fuzzy flag for the reuse lookup.
    return parse_entry_block([re.sub(r"^#~\s?", "", l) for l in block])


def parse_pot(path):
    # Parse a .pot; return ([entry dict, ...], POT-Creation-Date).
    blocks = split_blocks(path.read_text(encoding="utf-8"))
    if not blocks:
        raise ValueError(f"pot file is empty: {path}")
    return ([parse_entry_block(b) for b in blocks[1:]],
            header_field(blocks[0], "POT-Creation-Date"))


def dedup_occurrences(entries):
    # Drop repeated location comments, keeping the first of each and the order. The
    # extractor records one token per _() call, so a line calling _() twice lists the
    # same file:line twice; gettext treats locations as a set. Rewriting in place is
    # what reaches the output, which emits occurrences verbatim.
    for entry in entries:
        seen, kept = set(), []
        for o in entry["occurrences"]:
            if o in seen:
                continue
            seen.add(o)
            kept.append(o)
        entry["occurrences"] = kept


def entries_from_blocks(blocks):
    # Extract an old .po in one pass into two maps, both keyed by msgid: the live
    # entries and the #~ ones gettext wrote for strings the pot dropped.
    live, obsolete = {}, {}
    for block in blocks[1:]:  # skip the header
        if any(l.startswith("#~") for l in block):
            entry, target = parse_obsolete_block(block), obsolete
        else:
            entry, target = parse_entry_block(block), live
        if entry["msgid"] is not None:
            target[match_key(joined(entry["msgid"]))] = entry
    return live, obsolete


def header_field(header_block, key):
    # Pull a field's value out of the header block; "" when missing. The trailing \n
    # in "Key: value\n" is a literal escape, not a real newline.
    pattern = r'^"' + re.escape(key) + r':\s*(.*?)\\n"\s*$'
    for line in header_block:
        m = re.match(pattern, line)
        if m:
            return m.group(1)
    return ""


def po_escape(s):
    # Escape a value so it is valid inside a .po double-quoted literal.
    return s.replace("\\", "\\\\").replace('"', '\\"')


def project_id(name):
    # Derive the gettext project id from a display name: lowercase, whitespace removed.
    return "".join(name.lower().split())


def build_header(layout, code, pot_date, rev_date, translator, fuzzy):
    # Build the .po header (field order fixed).
    team = LANG_NAME[code]
    year = time.strftime("%Y")
    # Dropped as a whole line rather than emitted empty: no flag is what gettext reads
    # as "not fuzzy", an empty flag line would be meaningless.
    flag_line = ["#, fuzzy"] if fuzzy else []
    # Same for the translator: a value is only inherited from the old .po, never
    # invented here, and an old header without the field must not grow an empty one.
    translator_line = (
        [f'"Last-Translator: {translator}\\n"'] if translator else []
    )
    return [
        f"# {layout.fullname} — KOReader Plugin",
        f"# {team} translation",
        f"# Copyright (C) {year} {layout.fullname} Contributors",
        f"# This file is distributed under the same license as the {layout.project_id} package.",
        "#",
    ] + flag_line + [
        'msgid ""',
        'msgstr ""',
        f'"Project-Id-Version: {po_escape(layout.project_id)}\\n"',
        f'"POT-Creation-Date: {pot_date}\\n"',
        f'"PO-Revision-Date: {rev_date}\\n"',
    ] + translator_line + [
        f'"Language-Team: {team}\\n"',
        f'"Language: {code}\\n"',
        f'"MIME-Version: 1.0\\n"',
        f'"Content-Type: text/plain; charset=UTF-8\\n"',
        f'"Content-Transfer-Encoding: 8bit\\n"',
        f'"Plural-Forms: {PLURAL_FORMS}\\n"',
    ]


def joined(lines):
    # Join a field's physical lines back into its literal content.
    return "".join(lines or [])


def field_lines(name, lines):
    # Emit one field on the lines it already has: the first carries the field name,
    # the rest are continuations. An empty field yields `name ""`.
    if not lines:
        return [f'{name} ""']
    return [f'{name} "{lines[0]}"'] + [f'"{l}"' for l in lines[1:]]


def format_fields(entry):
    # Emit the three translation fields on the physical lines they already have.
    lines = field_lines("msgid", entry["msgid"])
    if entry["msgid_plural"] is not None:
        lines.extend(field_lines("msgid_plural", entry["msgid_plural"]))
        for i in sorted(entry["msgstrs"]):
            lines.extend(field_lines(f"msgstr[{i}]", entry["msgstrs"][i]))
    else:
        lines.extend(field_lines("msgstr", entry["msgstrs"].get(0, [""])))
    return lines


def format_entry_block(entry):
    # Format one entry: comments + locations, then every field on its own lines.
    lines = list(entry["comment_lines"])
    lines.extend(f"#: {o}" for o in entry["occurrences"])
    # gettext puts flags after the references and before msgid. A flag line already
    # in the source is listed above, so adding another would write it twice.
    if entry["fuzzy"] and not any(is_fuzzy_flag_line(l) for l in entry["comment_lines"]):
        lines.append("#, fuzzy")
    lines.extend(format_fields(entry))
    return lines


def format_obsolete_block(entry):
    # Emit a dropped entry the way gettext writes it: every field line behind "#~ ",
    # so msgfmt ignores it while the text stays restorable; fuzzy goes with it.
    flag = ["#~ #, fuzzy"] if entry["fuzzy"] else []
    return flag + [f"#~ {l}" for l in format_fields(entry)]


def rename_to_old(locale_dir, codes):
    # Rename the selected *.po to *_old.po; abort if any *_old.po already exists.
    for code in codes:
        if old_po_path(locale_dir, code).exists():
            print(f"  Aborted: {old_po_path(locale_dir, code).name} already exists; check and handle it manually first.")
            sys.exit(1)
    for code in codes:
        new_po, old_po = new_po_path(locale_dir, code), old_po_path(locale_dir, code)
        new_po.rename(old_po)


def restore_from_old(locale_dir, codes):
    # Rename *_old.po back to *.po; returns the restored filenames. rename_to_old()'s
    # precheck guarantees no *_old.po existed at startup; skip when the target *.po
    # exists (that language already succeeded) — never overwrite.
    restored = []
    for code in codes:
        old, new = old_po_path(locale_dir, code), new_po_path(locale_dir, code)
        if not old.exists() or new.exists():
            continue
        old.rename(new)
        restored.append(new.name)
    return restored


def drop_tmp_files(locale_dir, codes):
    # Remove the tmp files of a run that never reached the atomic replace. A leftover
    # is reported, not ignored: the next run fails writing the same tmp, so it must
    # be visible.
    for code in codes:
        tmp = tmp_po_path(locale_dir, code)
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass  # this language never got as far as writing one
        except OSError as exc:
            print(f"  Warning: could not remove {tmp.name} ({exc}); delete it by hand.")


def rollback(locale_dir, codes):
    # Undo a failed run: restore every renamed *.po and clear the tmp files. Shared
    # by the failed-check exit and the crash handler; returns the restored filenames.
    try:
        restored = restore_from_old(locale_dir, codes)
    except OSError:
        restored = []
        print("  Warning: failed to restore *_old.po; rename it back to *.po manually.")
    if restored:
        print(f"  Restored: {', '.join(restored)}")
    drop_tmp_files(locale_dir, codes)
    print("  No translation lost; fix the issues above and rerun this script.")
    return restored


def plural_shape_changed(entry, old):
    # True when the pot and the old .po disagree on whether the msgid is plural: the
    # old msgstr answers a different question, so every slot starts empty.
    if old is None:
        return False
    return (entry["msgid_plural"] is None) != (old["msgid_plural"] is None)


def reuse_source(translations, obsolete):
    # Live entries are the only source for a msgid they carry: a #~ copy with the
    # same msgid is stale and is dropped even when its msgstr differs, so one msgid
    # never appears both live and #~. The #~ section fills only msgids no live entry has.
    source = dict(translations)
    for key, old in obsolete.items():
        if key not in source:
            source[key] = old
    return source


def obsolete_entries(source, live_keys):
    # Everything the new file does not carry as a live entry, in A-Z order by msgid,
    # ignoring case. A msgid the pot took back is live now, so keeping it here too
    # would write the same string twice — once live, once #~.
    keys = sorted((k for k in source if k not in live_keys),
                  key=lambda k: (k.casefold(), k))
    return [source[k] for k in keys]


def build_entries(pot_entries, translations):
    # Rebuild translations from the pot entries: reuse the old ones (layout
    # included), leave gaps empty and flagged fuzzy, and keep an inherited fuzzy
    # flag for a second review; also return the key -> entry map plus the reused
    # and blank counts, which together are the live entry count.
    new_entries, by_key, reused, blank = [], {}, 0, 0
    for entry in pot_entries:
        key = match_key(joined(entry["msgid"]))
        old = translations.get(key)
        new_entry = dict(entry)
        old_msgstrs = old["msgstrs"] if old else {}
        # A plural entry carries its translation in msgstr[0] as well (both locales
        # are single-form); a msgid that only now gained a plural keeps every slot empty.
        slots = range(NPLURALS) if entry["msgid_plural"] is not None else (0,)
        plural_changed = plural_shape_changed(entry, old)
        new_entry["msgstrs"] = {i: [""] if plural_changed else old_msgstrs.get(i, [""]) for i in slots}
        filled = any(joined(new_entry["msgstrs"][i]).strip() for i in slots)
        # A fuzzy flag is a review marker, not a switch for the .mo: gettext leaves
        # fuzzy messages out, and that gap asks a reviewer for a second look. Inherit
        # it from any reused entry, live or #~, so it survives later rebuilds; an
        # empty msgstr gets one on its own, and removing a flag is a review decision
        # the script never makes by itself.
        new_entry["fuzzy"] = entry["fuzzy"] or not filled or bool(old and old["fuzzy"])
        # Reuse the old layout when the text is unchanged. A changed msgid has no
        # matching layout, so it goes out on the single line the pot gives us.
        for field in ("msgid", "msgid_plural"):
            if entry[field] is None:
                continue
            old_lines = old[field] if old else None
            if old_lines is not None and joined(old_lines) == joined(entry[field]):
                new_entry[field] = old_lines
        if filled:
            reused += 1
        else:
            blank += 1
        new_entries.append(new_entry)
        by_key.setdefault(key, new_entry)  # if the pot has duplicate msgids, keep the first
    return new_entries, by_key, reused, blank


def check_reuse(by_key, translations):
    # Check that no old translation was dropped: where the old one is non-empty and the
    # msgid is still in the pot, the new entry must be non-empty.
    issues = []
    for msgid, old in translations.items():
        new_entry = by_key.get(msgid)
        if new_entry is None:
            continue
        # A msgid whose plural shape changed is emptied on purpose, so the missing
        # slots are the expected outcome rather than a lost translation.
        if plural_shape_changed(new_entry, old):
            continue
        # Old indices beyond nplurals are unused at runtime, so they are dropped.
        old_has = {i: v for i, v in old["msgstrs"].items() if joined(v).strip() and i < NPLURALS}
        dropped = [i for i in old_has if not joined(new_entry["msgstrs"].get(i, [])).strip()]
        if dropped:
            issues.append(f"[reuse] translation dropped ({msgid!r}): old po index {dropped} is non-empty but the new entry is empty")
    return issues


def regenerate(layout, code, pot_entries, translations, obsolete, pot_date, translator):
    # Rebuild one language's .po: writes the tmp file only if every check passes;
    # returns ({reused, blank, obsolete}, issues) — the keys are what main() prints.
    rev_date = time.strftime("%Y-%m-%d %H:%M")

    source = reuse_source(translations, obsolete)
    new_entries, by_key, reused, blank = build_entries(pot_entries, source)
    issues = check_reuse(by_key, source)

    # The header flag follows the new file, not the old one: entries may gain or lose
    # fuzzy during the rebuild, so the old header says nothing about the file written.
    fuzzy = any(e["fuzzy"] for e in new_entries)

    header = build_header(layout, code, pot_date, rev_date, translator, fuzzy)
    blocks = [header] + [format_entry_block(e) for e in new_entries]
    obsolete_blocks = obsolete_entries(source, by_key)
    blocks.extend(format_obsolete_block(e) for e in obsolete_blocks)
    content = "\n\n".join("\n".join(b) for b in blocks) + "\n"

    if not issues:
        tmp_po_path(layout.locale_dir, code).write_text(content, encoding="utf-8", newline="\n")
    return {"reused": reused, "blank": blank,
            "obsolete": len(obsolete_blocks)}, issues


def main(argv):
    # Run the rebuild; a failed check or a crash rolls back through rollback().
    layout = resolve_paths(plugin_root(argv))
    locale_dir = layout.locale_dir
    codes = sorted(LANG_NAME)
    missing = [c for c in codes if not new_po_path(locale_dir, c).exists()]
    if missing:
        print(f"Aborted: {', '.join(new_po_path(locale_dir, c).name for c in missing)} not found in {locale_dir.name}/")
        sys.exit(1)
    try:
        pot_entries, pot_date = parse_pot(layout.pot_file)
        # Once for both languages: the entries are shared, so a location repeated in
        # the pot would otherwise be written out twice in every rebuilt .po.
        dedup_occurrences(pot_entries)

        rename_to_old(locale_dir, codes)

        results, old_counts = {}, {}
        for code in codes:
            old_blocks = split_blocks(old_po_path(locale_dir, code).read_text(encoding="utf-8"))
            translations, obsolete = entries_from_blocks(old_blocks)
            # A counts every entry of the old .po, the #~ section included.
            old_counts[code] = len(translations) + len(obsolete)
            # Who signed the old file stays on the new one: the field identifies the translator.
            translator = header_field(old_blocks[0], "Last-Translator")

            results[code] = regenerate(layout, code, pot_entries, translations, obsolete,
                                       pot_date, translator)

        failed = [c for c in codes if results[c][1]]
        for code in failed:
            print(f"[{code}] precheck failed, nothing written")
            for i in results[code][1]:
                print(f"    - {i}")

        if failed:
            # Nothing was replaced, so every *.po is still renamed away; put them
            # back before exiting so the runtime keeps both languages.
            print(f"Aborted: {', '.join(failed)} failed its checks.")
            rollback(locale_dir, codes)
            sys.exit(1)

        # Both languages passed, so the real .po files are replaced together: a
        # failure from here on can only leave one of them swapped.
        for code in codes:
            os.replace(tmp_po_path(locale_dir, code), new_po_path(locale_dir, code))
            stats = results[code][0]
            # reused and blank split the live entries by whether a msgstr exists,
            # and obsolete is the #~ section: the three are disjoint, so B is their sum.
            total = stats['reused'] + stats['blank'] + stats['obsolete']
            print(f"[{code}] Entries {old_counts[code]} to {total}  "
                  f"(reused {stats['reused']} / blank {stats['blank']} "
                  f"/ obsolete {stats['obsolete']})")
        for code in codes:
            old = old_po_path(locale_dir, code)
            if old.exists():
                old.unlink()
    except (OSError, ValueError) as exc:
        # A crash between rename_to_old() and generating the .po leaves no new .po while the
        # *.po has been renamed away; not restoring it would leave the runtime without
        # language files. The translations themselves are still in *_old.po.
        print(f"\nAborted: error reading or writing a file ({type(exc).__name__}): {exc}")
        rollback(locale_dir, codes)
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
