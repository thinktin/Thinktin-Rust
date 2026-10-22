#!/usr/bin/env python3
"""数据库迁移的发布检查（WBS 2.9，规则见 docs/release.md 第 3 节）。

发布时先执行迁移、再滚动更新程序，中间一段时间新旧两版程序同时连着新表结构；回滚时上一版程序也要能在
新表结构上跑。所以：

1. 发布过的迁移（最近一个 `v*` 标签里已有的）一个字节都不能改、不能删：sqlx 按内容的校验和核对，
   改了生产库就迁移不了、程序也拒绝启动。
2. 迁移文件名是 `NNNN_小写说明.sql`，编号从 0001 起连续。
3. 标签之后新加的迁移里，会让上一版程序出错的改动（删表删列、改名、改类型、加非空、删数据、收回权限……）
   要在语句前面的注释里写 `deploy-safe: <为什么上一版不受影响>`，比如“上一版已经不读这一列了”。
   会长时间锁表的改动（在已有的表上建索引、加约束、全表更新）只提醒。

用法：
  python3 tools/ci/check_migrations.py [--base <git 引用>] [--dir crates/store/migrations]
  python3 tools/ci/check_migrations.py --self-test

没有 `--base` 时取当前提交之前最近的 `v*` 标签；还没有标签（没发布过）时只查文件名。
在 GitHub Actions 里问题写成注解。
"""

import argparse
import os
import re
import subprocess
import sys

DEFAULT_DIR = "crates/store/migrations"
NAME = re.compile(r"^(\d{4})_[a-z0-9_]+\.sql$")
ACK = re.compile(r"deploy-safe:\s*\S")


# ---------- 拆语句 ----------


class Statement:
    def __init__(self, line, text, comments):
        self.line = line  # 语句从第几行开始（1 起）
        self.text = text  # 去掉注释、字符串内容换成占位、空白合并、大写
        self.comments = comments  # 语句前面（上一条语句之后）的注释

    def acknowledged(self):
        return any(ACK.search(c) for c in self.comments)


def split_statements(sql):
    """按分号拆成语句；注释、字符串、$$ 包起来的函数体里的分号不算。"""
    out = []
    i, n, line = 0, len(sql), 1
    buf = []  # 当前语句规整后的片段
    comments = []
    start = None  # 当前语句第一个有效字符所在的行

    def flush():
        nonlocal buf, comments, start
        text = " ".join("".join(buf).split()).upper()
        if text:
            out.append(Statement(start or line, text, comments))
        buf, comments, start = [], [], None

    while i < n:
        c = sql[i]
        if c == "\n":
            line += 1
            buf.append(" ")
            i += 1
        elif sql.startswith("--", i):
            end = sql.find("\n", i)
            end = n if end < 0 else end
            comments.append(sql[i + 2 : end])
            i = end
        elif sql.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if sql.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif sql.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            comments.append(sql[i + 2 : j - 2])
            line += sql.count("\n", i, j)
            i = j
        elif c == "'" or (c in "eE" and sql.startswith("'", i + 1) and not _word(sql, i - 1)):
            if start is None:
                start = line
            j = i + (2 if c != "'" else 1)
            backslash = c != "'"
            while j < n:
                if backslash and sql[j] == "\\":
                    j += 2
                    continue
                if sql[j] == "'":
                    if sql.startswith("''", j):
                        j += 2
                        continue
                    j += 1
                    break
                j += 1
            line += sql.count("\n", i, j)
            buf.append(" 'S' ")
            i = j
        elif c == '"':
            if start is None:
                start = line
            j = sql.find('"', i + 1)
            j = n if j < 0 else j + 1
            buf.append(sql[i + 1 : j - 1].replace(" ", "_"))
            i = j
        elif c == "$" and (m := re.match(r"\$([A-Za-z_][A-Za-z0-9_]*)?\$", sql[i:])) and not _word(sql, i - 1):
            if start is None:
                start = line
            tag = m.group(0)
            end = sql.find(tag, i + len(tag))
            end = n if end < 0 else end + len(tag)
            line += sql.count("\n", i, end)
            buf.append(" $BODY$ ")
            i = end
        elif c == ";":
            flush()
            i += 1
        else:
            if start is None and not c.isspace():
                start = line
            buf.append(c)
            i += 1
    flush()
    return out


def _word(s, i):
    return i >= 0 and (s[i].isalnum() or s[i] in "_$")


# ---------- 规则 ----------

IDENT = r'([A-Z0-9_."]+)'


def table_name(raw):
    name = raw.strip('"').lower()
    return name[len("public.") :] if name.startswith("public.") else name


def split_actions(body):
    """ALTER TABLE 的动作按顶层逗号拆开。"""
    parts, depth, cur = [], 0, []
    for ch in body:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur).strip())
    return [p for p in parts if p]


CREATE = re.compile(
    r"CREATE (?:OR REPLACE )?(?:UNLOGGED |TEMP |TEMPORARY )?(?:UNIQUE )?"
    r"(?:TABLE|VIEW|MATERIALIZED VIEW|TYPE|DOMAIN|FUNCTION|PROCEDURE|SCHEMA|SEQUENCE|INDEX(?: CONCURRENTLY)?) "
    r"(?:IF NOT EXISTS )?" + IDENT
)


def lint(statements):
    """返回 [(级别, 行号, 说明)]，级别是 error 或 warning。同一个迁移里新建的对象还没发布过，随便改。"""
    created = set()
    for s in statements:
        m = CREATE.match(s.text)
        if m:
            created.add(table_name(m.group(1)))

    findings = []

    def breaking(s, obj, what):
        if obj in created or s.acknowledged():
            return
        findings.append(
            (
                "error",
                s.line,
                what
                + "：上一版程序可能出错（滚动发布、回滚时它还连着这个库）。确实不影响的话，在语句前写注释"
                "“-- deploy-safe: 原因”；否则分两次发布（先发不再依赖它的程序，下一次再改表）",
            )
        )

    def slow(s, what):
        findings.append(("warning", s.line, what))

    for s in statements:
        t = s.text
        m = re.match(
            r"DROP (TABLE|VIEW|MATERIALIZED VIEW|TYPE|DOMAIN|FUNCTION|PROCEDURE|SCHEMA|SEQUENCE|INDEX) "
            r"(?:CONCURRENTLY )?(?:IF EXISTS )?" + IDENT,
            t,
        )
        if m:
            breaking(s, table_name(m.group(2)), "删除了 %s %s" % (m.group(1).lower(), table_name(m.group(2))))
            continue
        m = re.match(r"TRUNCATE (?:TABLE )?(?:ONLY )?" + IDENT, t)
        if m:
            breaking(s, table_name(m.group(1)), "清空了表 %s" % table_name(m.group(1)))
            continue
        m = re.match(r"DELETE FROM (?:ONLY )?" + IDENT, t)
        if m and " WHERE " not in t + " ":
            breaking(s, table_name(m.group(1)), "删除了 %s 的全部数据" % table_name(m.group(1)))
            continue
        if re.match(r"REVOKE\b", t):
            m = re.search(r" ON (?:TABLE |FUNCTION |PROCEDURE |SEQUENCE |SCHEMA |TYPE )?" + IDENT, t)
            breaking(s, table_name(m.group(1)) if m else None, "收回了权限")
            continue
        m = re.match(
            r"ALTER (TYPE|VIEW|MATERIALIZED VIEW|FUNCTION|PROCEDURE|SCHEMA|SEQUENCE|INDEX|DOMAIN) "
            r"(?:IF EXISTS )?" + IDENT,
            t,
        )
        if m:
            obj = table_name(m.group(2))
            if re.search(r"\bRENAME (TO|ATTRIBUTE|VALUE)\b", t):
                breaking(s, obj, "改了 %s %s 的名字" % (m.group(1).lower(), obj))
            elif re.search(r"\bDROP (VALUE|ATTRIBUTE)\b", t):
                breaking(s, obj, "删除了类型 %s 的取值或字段" % obj)
            continue
        m = re.match(r"ALTER TABLE (?:IF EXISTS )?(?:ONLY )?" + IDENT + r" (.*)$", t)
        if m:
            table = table_name(m.group(1))
            new = table in created
            for action in split_actions(m.group(2)):
                if re.match(r"DROP (COLUMN )?(IF EXISTS )?(?!CONSTRAINT\b)", action):
                    breaking(s, table, "删除了 %s 的列" % table)
                elif re.match(r"RENAME (COLUMN |TO )?", action) and not action.startswith("RENAME CONSTRAINT"):
                    breaking(s, table, "改了 %s 的表名或列名" % table)
                elif re.match(r"ALTER (COLUMN )?\S+ (SET DATA )?TYPE\b", action):
                    breaking(s, table, "改了 %s 的列类型" % table)
                elif re.match(r"ALTER (COLUMN )?\S+ SET NOT NULL\b", action):
                    breaking(s, table, "把 %s 的列改成了非空" % table)
                elif (
                    re.match(
                        r"ADD (COLUMN )?(IF NOT EXISTS )?"
                        r"(?!CONSTRAINT\b|CHECK\b|UNIQUE\b|PRIMARY\b|FOREIGN\b|EXCLUDE\b)\S+ ",
                        action,
                    )
                    and re.search(r"\bNOT NULL\b", action)
                    and not re.search(r"\bDEFAULT\b", action)
                    and not re.search(r"\bGENERATED\b", action)
                ):
                    breaking(s, table, "给 %s 加了没有默认值的非空列（上一版插入时不会填它）" % table)
                elif (
                    re.match(r"ADD (CONSTRAINT \S+ )?(CHECK|UNIQUE|PRIMARY KEY|FOREIGN KEY|EXCLUDE)\b", action)
                    and "NOT VALID" not in action
                    and not new
                ):
                    slow(s, "在已有的表 %s 上加约束：要扫全表、期间锁写入；上一版写的数据也要满足它" % table)
            continue
        m = re.match(r"CREATE (?:UNIQUE )?INDEX (CONCURRENTLY )?.*? ON (?:ONLY )?" + IDENT, t)
        if m:
            table = table_name(m.group(2))
            if not m.group(1) and table not in created:
                slow(
                    s,
                    "在已有的表 %s 上建索引会锁写入直到建完；表大了改用 CREATE INDEX CONCURRENTLY"
                    "（放在单独的、第一行写 -- no-transaction 的迁移里）" % table,
                )
            continue
        m = re.match(r"UPDATE (?:ONLY )?" + IDENT + r" ", t)
        if m and " WHERE " not in t + " " and table_name(m.group(1)) not in created:
            slow(s, "全表更新 %s：在一个事务里改写每一行，表大了要分批" % table_name(m.group(1)))
    return findings


# ---------- 文件和 git ----------


def git(*args, check=True):
    r = subprocess.run(["git", *args], capture_output=True)
    if check and r.returncode != 0:
        sys.exit("git %s: %s" % (" ".join(args), r.stderr.decode().strip()))
    return r


def latest_release():
    r = git("describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", "HEAD", check=False)
    return r.stdout.decode().strip() or None if r.returncode == 0 else None


def released(base, directory):
    out = git("ls-tree", "--name-only", base, directory + "/").stdout.decode().split()
    return sorted(os.path.basename(p) for p in out if p.endswith(".sql"))


def report(findings):
    actions = os.environ.get("GITHUB_ACTIONS") == "true"
    errors = 0
    for level, path, line, message in findings:
        errors += level == "error"
        if actions:
            print("::%s file=%s,line=%d::%s" % (level, path, line or 1, message))
        else:
            print("%s:%d: %s: %s" % (path, line or 1, level, message))
    return errors


def check(directory, base):
    findings = []
    names = sorted(f for f in os.listdir(directory) if f.endswith(".sql"))
    numbers = []
    for name in names:
        m = NAME.match(name)
        if not m:
            findings.append(("error", os.path.join(directory, name), 1, "迁移文件名要写成 NNNN_小写说明.sql"))
            continue
        numbers.append(int(m.group(1)))
    if numbers != list(range(1, len(numbers) + 1)):
        findings.append(
            ("error", directory, 1, "迁移编号要从 0001 起连续、不重复，现在是 %s" % ", ".join("%04d" % n for n in numbers))
        )

    if base is None:
        print("还没有发布标签（v*）：没有发布过的迁移，只查文件名。")
        return findings
    old = released(base, directory)
    print("对照 %s：发布过 %d 个迁移，新加 %d 个。" % (base, len(old), len(set(names) - set(old))))
    for name in old:
        path = os.path.join(directory, name)
        if name not in names:
            findings.append(("error", path, 1, "%s 里发布过的迁移被删了：生产库里有它，迁移和启动都会失败" % base))
            continue
        before = git("show", "%s:%s" % (base, path)).stdout
        with open(path, "rb") as f:
            if f.read() != before:
                findings.append(
                    ("error", path, 1, "%s 里发布过的迁移被改了：按校验和核对，生产库会拒绝；要改表请加新的迁移" % base)
                )
    for name in names:
        if name in old or not NAME.match(name):
            continue
        path = os.path.join(directory, name)
        with open(path, encoding="utf-8") as f:
            for level, line, message in lint(split_statements(f.read())):
                findings.append((level, path, line, message))
    return findings


# ---------- 自测 ----------

SELF_TEST = [
    # （SQL，期望的 [(级别, 行号)]）
    ("CREATE TABLE t (id int NOT NULL);\nALTER TABLE t ADD COLUMN x int NOT NULL;", []),
    ("ALTER TABLE runs ADD COLUMN x int NOT NULL;", [("error", 1)]),
    ("ALTER TABLE runs ADD COLUMN x int NOT NULL DEFAULT 0;", []),
    ("ALTER TABLE runs ADD COLUMN x timestamptz;", []),
    ("\n\nALTER TABLE runs DROP COLUMN x;", [("error", 3)]),
    ("-- deploy-safe: 上一版已经不读 x 了\nALTER TABLE runs DROP COLUMN x;", []),
    ("-- deploy-safe:\nALTER TABLE runs DROP COLUMN x;", [("error", 2)]),
    ("ALTER TABLE runs DROP CONSTRAINT runs_kind_check, ADD CONSTRAINT runs_kind_check CHECK (kind IN ('a', 'b'));",
     [("warning", 1)]),
    ("ALTER TABLE runs ADD CONSTRAINT c CHECK (x > 0) NOT VALID;", []),
    ("ALTER TABLE runs RENAME COLUMN a TO b;", [("error", 1)]),
    ("ALTER TABLE runs RENAME TO jobs;", [("error", 1)]),
    ("ALTER TABLE runs ALTER COLUMN a TYPE bigint;", [("error", 1)]),
    ("ALTER TABLE runs ALTER COLUMN a SET NOT NULL, ALTER COLUMN b DROP NOT NULL;", [("error", 1)]),
    ("ALTER TABLE runs ALTER COLUMN b DROP NOT NULL, ALTER COLUMN c SET DEFAULT 1;", []),
    ("DROP TABLE old_things;", [("error", 1)]),
    ("DROP INDEX IF EXISTS runs_by_state;", [("error", 1)]),
    ("DROP POLICY tenant ON runs;\nCREATE POLICY tenant ON runs USING (true);", []),
    ("DROP TRIGGER t ON runs;", []),
    ("REVOKE SELECT ON runs FROM thinktin_app;", [("error", 1)]),
    ("CREATE FUNCTION f() RETURNS trigger AS $$ BEGIN RETURN OLD; END $$ LANGUAGE plpgsql;\n"
     "REVOKE ALL ON FUNCTION f() FROM PUBLIC;", []),
    ("CREATE TABLE t (a int);\nALTER TABLE t DROP COLUMN a;\nDROP TABLE t;", []),
    ("DROP TABLE IF EXISTS public.old_things;", [("error", 1)]),
    ("TRUNCATE outbox;", [("error", 1)]),
    ("DELETE FROM outbox;", [("error", 1)]),
    ("DELETE FROM outbox WHERE delivered_at IS NOT NULL;", []),
    ("CREATE INDEX runs_by_x ON runs (x);", [("warning", 1)]),
    ("CREATE INDEX CONCURRENTLY runs_by_x ON runs (x);", []),
    ("CREATE TABLE things (id int);\nCREATE UNIQUE INDEX things_by_id ON things (id);", []),
    ("UPDATE device_messages SET notified_at = created_at;", [("warning", 1)]),
    ("UPDATE runs SET x = 1 WHERE id = 'a';", []),
    ("ALTER TYPE run_state RENAME VALUE 'a' TO 'b';", [("error", 1)]),
    ("ALTER TYPE run_state ADD VALUE 'c';", []),
    # 注释、字符串、函数体里的分号和关键字不算。
    ("/* DROP TABLE runs; */ SELECT 1; -- DROP TABLE runs;\nSELECT ';DROP TABLE runs;';", []),
    ("CREATE FUNCTION f() RETURNS void AS $$ BEGIN DELETE FROM runs; END $$ LANGUAGE plpgsql;", []),
    ("DO $body$ BEGIN DROP TABLE x; END $body$;", []),
    ("SELECT 'it''s; DROP TABLE runs';\nDROP TABLE runs;", [("error", 2)]),
    ("SELECT E'a\\'; DROP TABLE runs';", []),
    ('ALTER TABLE "Runs" DROP COLUMN "My Col";', [("error", 1)]),
    ("ALTER TABLE public.runs ADD COLUMN y int NOT NULL GENERATED ALWAYS AS (1) STORED;", []),
]


def self_test():
    failed = 0
    for sql, want in SELF_TEST:
        got = [(level, line) for level, line, _ in lint(split_statements(sql))]
        if got != want:
            failed += 1
            print("FAIL: %r\n  want %r\n  got  %r" % (sql, want, got))
    # 行号跟着多行注释、字符串走。
    s = split_statements("/* a\nb */\nSELECT 'x\ny';\n\nDROP TABLE t;")
    if [st.line for st in s] != [3, 6]:
        failed += 1
        print("FAIL: line numbers %r" % [st.line for st in s])
    print("self-test: %d cases, %d failed" % (len(SELF_TEST) + 1, failed))
    return failed == 0


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--base", help="对照的发布（git 引用），默认最近的 v* 标签")
    p.add_argument("--dir", default=DEFAULT_DIR)
    p.add_argument("--self-test", action="store_true")
    args = p.parse_args()
    if args.self_test:
        sys.exit(0 if self_test() else 1)
    base = args.base or latest_release()
    errors = report(check(args.dir, base))
    if errors:
        print("%d 个问题要处理（规则见 docs/release.md 第 3 节）。" % errors)
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
