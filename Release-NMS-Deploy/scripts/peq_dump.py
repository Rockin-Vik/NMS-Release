"""Stream INSERT rows from the PEQ mysqldump zip (latin-1)."""

from __future__ import annotations

import zipfile
from pathlib import Path


def parse_sql_int(value) -> int:
    if value is None or value == "NULL":
        return 0
    if isinstance(value, int):
        return value
    text = str(value).strip()
    if text in {"", "NULL"}:
        return 0
    if "." in text:
        return int(float(text))
    return int(text)


def parse_sql_str(value) -> str:
    if value is None or value == "NULL":
        return ""
    return str(value)


class InsertRowReader:
    """Stream INSERT INTO `table` VALUES rows from a mysqldump inside a zip."""

    def __init__(self, dump_path: Path):
        self.dump_path = dump_path

    def iter_rows(self, table: str):
        prefix = f"INSERT INTO `{table}` VALUES"
        leftover = ""
        in_table = False
        with zipfile.ZipFile(self.dump_path) as zf:
            with zf.open(zf.namelist()[0]) as raw:
                while True:
                    chunk = raw.read(8 * 1024 * 1024)
                    if not chunk:
                        if in_table and leftover:
                            yield from self._emit_complete(leftover, prefix, final=True)
                        return
                    text = leftover + chunk.decode("latin-1")
                    leftover = ""
                    if not in_table:
                        idx = text.find(prefix)
                        if idx < 0:
                            leftover = text[-len(prefix) :] if len(text) >= len(prefix) else text
                            continue
                        text = text[idx:]
                        in_table = True
                    stop = text.find("\nCREATE TABLE `")
                    if stop != -1:
                        yield from self._emit_complete(text[:stop], prefix, final=True)
                        return
                    leftover = yield from self._emit_complete(text, prefix, final=False)

    def _emit_complete(self, text: str, prefix: str, final: bool):
        pos = 0
        while True:
            start = text.find(prefix, pos)
            if start < 0:
                return text[pos:] if not final else ""
            rows, end, complete = _parse_values_block(text, start + len(prefix))
            if complete:
                yield from rows
                pos = end
                continue
            if final:
                yield from rows
                return ""
            return text[start:]


def _parse_values_block(text: str, i: int):
    rows = []
    n = len(text)
    complete = False
    while i < n:
        while i < n and text[i] in " \t\r\n":
            i += 1
        if i >= n:
            break
        if text[i] == ";":
            complete = True
            return rows, i + 1, complete
        if text[i] == ",":
            i += 1
            continue
        if text[i] != "(":
            break
        row, i, ok = _parse_tuple(text, i)
        if not ok:
            return rows, i, False
        rows.append(row)
    return rows, i, complete


def _parse_tuple(text: str, i: int):
    assert text[i] == "("
    i += 1
    fields = []
    n = len(text)
    while i < n:
        while i < n and text[i] in " \t\r\n":
            i += 1
        if i >= n:
            return fields, i, False
        if text.startswith("NULL", i) and (i + 4 >= n or text[i + 4] in ",)"):
            fields.append(None)
            i += 4
        elif text[i] == "'":
            value, i = _parse_quoted(text, i)
            if value is None:
                return fields, i, False
            fields.append(value)
        else:
            j = i
            while j < n and text[j] not in ",)":
                j += 1
            fields.append(text[i:j].strip())
            i = j
        while i < n and text[i] in " \t\r\n":
            i += 1
        if i >= n:
            return fields, i, False
        if text[i] == ",":
            i += 1
            continue
        if text[i] == ")":
            return fields, i + 1, True
        return fields, i, False
    return fields, i, False


def _parse_quoted(text: str, i: int):
    assert text[i] == "'"
    i += 1
    out = []
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == "\\":
            if i + 1 >= n:
                return None, i
            nxt = text[i + 1]
            escapes = {"n": "\n", "r": "\r", "t": "\t", "0": "\0", "'": "'", '"': '"', "\\": "\\"}
            out.append(escapes.get(nxt, nxt))
            i += 2
            continue
        if ch == "'":
            if i + 1 < n and text[i + 1] == "'":
                out.append("'")
                i += 2
                continue
            return "".join(out), i + 1
        out.append(ch)
        i += 1
    return None, i
