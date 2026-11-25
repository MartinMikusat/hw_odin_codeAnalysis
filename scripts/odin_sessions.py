#!/usr/bin/env python3
import argparse, datetime, glob, json, os, re, sqlite3

HOME = os.path.expanduser("~")
DEFAULT_OUTPUT = os.path.join(HOME, "Library/Application Support/hw_odin_codeAnalysis/sessions.db")
parser = argparse.ArgumentParser(
    description="Extract tool calls and messages of local agent sessions into a private SQLite database.")
parser.add_argument("--out", default=DEFAULT_OUTPUT, help="database path, outside any repository")
parser.add_argument("--exclude", action="append", default=[], help="skip Claude Code sessions with this ID")
options = parser.parse_args()
os.makedirs(os.path.dirname(os.path.abspath(options.out)), exist_ok=True)
os.close(os.open(options.out, os.O_CREAT | os.O_WRONLY, 0o600))
os.chmod(options.out, 0o600)
PRIVATE = re.compile(r"hw[_-]health(?!\S*\.odin)")
HEALTH_DATA = re.compile(r"hw[_-]health\S*\s+(log|add|list|total|query|trend|avg|day|week|show|export)|\.sqlite|\.db\b")

db = sqlite3.connect(options.out)
db.executescript("""
drop table if exists calls; drop table if exists msgs; drop table if exists odin_sessions;
create table calls(harness, session, ts real, cwd, model, kind, tool, input, output, exit int, err int, dur real);
create table msgs(harness, session, ts real, cwd, model, role, text);
""")


def stamp(s):
    if isinstance(s, (int, float)):
        return s / 1000 if s > 1e11 else s
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0


def text_of(c):
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(x.get("text", "") for x in c if isinstance(x, dict))
    return ""


def call(h, s, ts, cwd, model, kind, tool, inp, out, ex, err, dur):
    inp = inp or ""
    out = out or ""
    if PRIVATE.search(inp + " " + (cwd or "")) and HEALTH_DATA.search(inp):
        out = "[redacted]"
        inp = "[redacted health data command]"
    if len(out) > 60000:
        out = out[:30000] + "\n…\n" + out[-30000:]
    db.execute("insert into calls values(?,?,?,?,?,?,?,?,?,?,?,?)",
               (h, s, ts, cwd, model, kind, tool, inp[:40000], out, ex, int(bool(err)), dur))


def msg(h, s, ts, cwd, model, role, text):
    if text:
        db.execute("insert into msgs values(?,?,?,?,?,?,?)", (h, s, ts, cwd, model, role, text[:20000]))


def lines(f):
    with open(f, errors="replace") as fh:
        for l in fh:
            try:
                yield json.loads(l)
            except Exception:
                continue


seen = set()
for f in glob.glob(HOME + "/.claude/projects/*/**/*.jsonl", recursive=True):
    if any(session in f for session in options.exclude):
        continue
    s = os.path.relpath(f, HOME + "/.claude/projects")
    pend = {}
    for o in lines(f):
        m = o.get("message")
        if not isinstance(m, dict):
            continue
        ts, cwd, model = stamp(o.get("timestamp", "")), o.get("cwd"), m.get("model")
        c = m.get("content")
        if o.get("type") == "assistant" and isinstance(c, list):
            for x in c:
                if x.get("type") == "tool_use" and x["id"] not in seen:
                    seen.add(x["id"])
                    pend[x["id"]] = (ts, cwd, model, x["name"], x.get("input", {}))
                elif x.get("type") == "text":
                    msg("claude", s, ts, cwd, model, "assistant", x["text"])
        elif o.get("type") == "user":
            if isinstance(c, str):
                if not o.get("isMeta"):
                    msg("claude", s, ts, cwd, None, "user", c)
                continue
            for x in c or []:
                if x.get("type") == "tool_result" and x.get("tool_use_id") in pend:
                    t0, cw, md, name, inp = pend.pop(x["tool_use_id"])
                    out = text_of(x.get("content"))
                    ex = None
                    mm = re.match(r"Exit code (\d+)", out)
                    if mm:
                        ex = int(mm.group(1))
                    kind = "cmd" if name == "Bash" else "edit" if name in ("Edit", "Write", "MultiEdit", "NotebookEdit") else "read" if name == "Read" else "other"
                    call("claude", s, t0, cw, md, kind, name,
                         inp.get("command") if name == "Bash" else json.dumps(inp), out, ex, x.get("is_error"), ts - t0)
                elif x.get("type") == "text" and not o.get("isMeta"):
                    msg("claude", s, ts, cwd, None, "user", x["text"])

for f in glob.glob(HOME + "/.codex/sessions/**/*.jsonl", recursive=True):
    s = os.path.basename(f)
    cwd = model = None
    for o in lines(f):
        p = o.get("payload") or {}
        ts = stamp(o.get("timestamp", ""))
        t = o.get("type")
        if t in ("session_meta", "turn_context"):
            cwd = p.get("cwd", cwd)
            model = p.get("model", model)
        elif t == "event_msg" and p.get("type") == "item_completed":
            it = p.get("item", {})
            k = it.get("type")
            if k == "CommandExecution":
                cmd = it.get("command")
                if isinstance(cmd, list):
                    cmd = cmd[2] if len(cmd) == 3 and cmd[1] in ("-lc", "-c") else " ".join(cmd)
                d = it.get("duration")
                if isinstance(d, dict):
                    d = d.get("secs", 0) + d.get("nanos", 0) / 1e9
                call("codex", s, ts - (d or 0), (it.get("cwd") or "").replace("file://", ""), model, "cmd", "exec_command",
                     cmd, it.get("aggregated_output"), it.get("exit_code"), it.get("status") == "failed", d)
            elif k == "FileChange":
                call("codex", s, ts, cwd, model, "edit", "apply_patch", json.dumps(it.get("changes")),
                     (it.get("stdout") or "") + (it.get("stderr") or ""), None, it.get("status") != "completed", None)
            elif k in ("UserMessage", "AgentMessage"):
                msg("codex", s, ts, cwd, model, "user" if k == "UserMessage" else "assistant", text_of(it.get("content")))
            elif k == "McpToolCall":
                call("codex", s, ts, cwd, model, "other", f"{it.get('server')}.{it.get('tool')}",
                     json.dumps(it.get("arguments")), json.dumps(it.get("result")), None, it.get("status") == "failed", None)
        elif t == "response_item" and p.get("type") == "custom_tool_call_output":
            out = text_of(p.get("output"))
            if re.search(r"Script failed|apply_patch verification failed|Script error", out[:3000]):
                call("codex", s, ts, cwd, model, "script_error", "exec", "", out, None, True, None)

for f in glob.glob(HOME + "/.pi/agent/sessions/**/*.jsonl", recursive=True):
    s = os.path.relpath(f, HOME + "/.pi/agent/sessions")
    cwd = model = None
    pend = {}
    for o in lines(f):
        if o.get("type") == "session":
            cwd = o.get("cwd")
        if o.get("type") == "model_change":
            model = o.get("modelId")
        m = o.get("message")
        if not isinstance(m, dict):
            continue
        ts = stamp(o.get("timestamp", ""))
        r = m.get("role")
        c = m.get("content")
        if r == "assistant":
            for x in c if isinstance(c, list) else []:
                if x.get("type") == "toolCall":
                    pend[x["id"]] = (ts, x["name"], x.get("arguments") or {})
                elif x.get("type") == "text":
                    msg("pi", s, ts, cwd, model, r, x.get("text"))
        elif r == "toolResult" and m.get("toolCallId") in pend:
            t0, name, inp = pend.pop(m["toolCallId"])
            out = text_of(c)
            mm = re.search(r"Command exited with code (\d+)", out)
            kind = "cmd" if name == "bash" else "edit" if name in ("edit", "write", "apply_patch") else "read" if name == "read" else "other"
            call("pi", s, t0, cwd, model, kind, name, inp.get("command") if name == "bash" else json.dumps(inp),
                 out, int(mm.group(1)) if mm else None, m.get("isError"), ts - t0)
        elif r == "user":
            msg("pi", s, ts, cwd, model, r, text_of(c))

OPENCODE = os.path.join(HOME, ".local/share/opencode/opencode.db")
oc = sqlite3.connect(f"file:{OPENCODE}?mode=ro", uri=True) if os.path.exists(OPENCODE) else sqlite3.connect(":memory:")
if not os.path.exists(OPENCODE):
    oc.executescript("create table session(id, directory); create table message(id, data);"
                     "create table part(message_id, session_id, time_created, data);")
sessions = {i: d for i, d in oc.execute("select id, directory from session")}
roles = {}
for i, d in oc.execute("select id, data from message"):
    j = json.loads(d)
    roles[i] = (j.get("role"), j.get("modelID") or (j.get("model") or {}).get("modelID"))
for mid, sid, ts, data in oc.execute("select message_id, session_id, time_created, data from part order by session_id, time_created"):
    j = json.loads(data)
    role, model = roles.get(mid, (None, None))
    cwd = sessions.get(sid)
    if j.get("type") == "text":
        msg("opencode", sid, ts / 1000, cwd, model, role, j.get("text"))
    elif j.get("type") == "tool":
        st = j.get("state", {})
        name = j.get("tool")
        inp = st.get("input") or {}
        md = st.get("metadata") or {}
        tm = st.get("time") or {}
        kind = "cmd" if name == "bash" else "edit" if name in ("edit", "write", "apply_patch") else "read" if name == "read" else "other"
        ex = md.get("exit")
        call("opencode", sid, ts / 1000, cwd, model, kind, name, inp.get("command") if name == "bash" else json.dumps(inp),
             st.get("output") or st.get("error"), ex, st.get("status") == "error" or bool(ex),
             (tm.get("end", 0) - tm.get("start", 0)) / 1000 if tm.get("end") else None)

db.executescript("""
create index c1 on calls(harness, session, ts);
create table odin_sessions as
 select harness, session, count(*) n from calls
 where (kind='cmd' and (input like '%hw-odin%' or input like '%odin build%' or input like '%odin check%' or input like '%./build.sh%' and cwd like '%odin%'))
    or (kind='edit' and input like '%.odin%')
 group by harness, session;
create index c2 on odin_sessions(harness, session);
""")
db.commit()
for q in [
    "select harness, count(*) sessions, sum(n) from odin_sessions group by 1",
    "select c.harness, count(*) calls, sum(kind='cmd') cmds, sum(kind='edit') edits, sum(err) errs, date(min(ts),'unixepoch'), date(max(ts),'unixepoch') from calls c join odin_sessions using(harness,session) group by 1",
]:
    for r in db.execute(q):
        print(r)
