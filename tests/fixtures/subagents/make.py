# Builds the subagent-row fixtures for tests/run.sh: payloads (what Claude
# Code pipes into a subagentStatusLine command) and subagent transcripts in
# the layout Claude Code writes them in,
#   <project dir>/<session id>/subagents/agent-<task id>.jsonl
#   <project dir>/<session id>/subagents/workflows/wf_*/agent-<task id>.jsonl
# All synthetic: no real prompt, path or output. Generated rather than
# checked in because the timestamps are relative to the suite's pinned clock
# and two of the transcripts are megabytes.
#
#   python3 make.py <project-dir> <session-id> <now-epoch> <payload-out-dir>
import json, os, sys, time

proj, sid, now, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
sub = os.path.join(proj, sid, 'subagents')
wf = os.path.join(sub, 'workflows', 'wf_abc123')
os.makedirs(wf, exist_ok=True)
os.makedirs(out, exist_ok=True)
CWD = '/w/proj'


def iso(t):
    return time.strftime('%Y-%m-%dT%H:%M:%S.000Z', time.gmtime(t))


_n = [0]
def use(name, inp, t):
    _n[0] += 1
    tid = 'toolu_%04d' % _n[0]
    return tid, {'type': 'assistant', 'timestamp': iso(t), 'isSidechain': True,
                 'message': {'role': 'assistant', 'content': [
                     {'type': 'tool_use', 'id': tid, 'name': name, 'input': inp}]}}


def result(tid, t, text='ok'):
    return {'type': 'user', 'timestamp': iso(t), 'isSidechain': True,
            'message': {'role': 'user', 'content': [
                {'type': 'tool_result', 'tool_use_id': tid, 'content': text}]}}


def say(t, s):
    return {'type': 'assistant', 'timestamp': iso(t),
            'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': s}]}}


def write(path, lines, pad=0):
    """pad: bytes of finished tool calls written first, so the tail read
    has to seek past them."""
    with open(path, 'w') as f:
        t = now - 3000
        while pad > 0:
            a, l = use('Read', {'file_path': '/w/pad.py'}, t)
            r = result(a, t, 'x' * 4000)
            s = json.dumps(l) + '\n' + json.dumps(r) + '\n'
            f.write(s)
            pad -= len(s)
        for l in lines:
            f.write(json.dumps(l) + '\n')


def running(agent, name, inp, ago=120, where=sub, extra=(), pad=0):
    """A transcript whose last call (name, inp) started `ago` seconds before
    now and has no result yet, after one call that has finished."""
    t0 = now - ago - 30
    a, l1 = use('Read', {'file_path': '/w/done.py'}, t0)
    lines = [say(t0 - 5, 'starting'), l1, result(a, t0 + 1)]
    b, l2 = use(name, inp, now - ago)
    lines.append(l2)
    for n2, i2 in extra:
        lines.append(use(n2, i2, now - ago + 5)[1])
    write(os.path.join(where, 'agent-%s.jsonl' % agent), lines, pad)


def finished(agent, end_ago=30):
    a, l1 = use('Bash', {'command': 'codex exec -m gpt-6-astra "x"'}, now - end_ago - 60)
    write(os.path.join(sub, 'agent-%s.jsonl' % agent),
          [l1, result(a, now - end_ago - 1), say(now - end_ago, 'done')])


def task(tid, status='running', desc=None, **kw):
    t = {'id': tid, 'type': 'local_agent', 'status': status,
         'description': desc if desc is not None else 'task ' + tid,
         'label': desc if desc is not None else 'task ' + tid,
         'startTime': (now - 300) * 1000, 'model': 'claude-haiku-4-5-20251001',
         'contextWindowSize': 200000, 'tokenCount': 24000,
         'tokenSamples': [0, 2000, 5000, 9000, 14000, 20000, 24000], 'cwd': CWD}
    t.update(kw)
    return {k: v for k, v in t.items() if v is not None}


def payload(name, tasks, columns=200, **kw):
    d = {'session_id': sid, 'transcript_path': os.path.join(proj, sid + '.jsonl'),
         'cwd': CWD, 'prompt_id': 'p-1', 'columns': columns, 'tasks': tasks}
    d.update(kw)
    with open(os.path.join(out, name + '.json'), 'w') as f:
        json.dump(d, f)


# --- every worker pattern, as a running Bash call ----------------------------
WORKERS = {
    'w-codex': 'codex exec -m gpt-6-astra "review the diff" 2>&1 | tee /tmp/log',
    'w-codex-wrapped': 'cd /w && timeout 900 env OPENAI_LOG=1 codex exec --model=o5-mini "x"',
    'w-codex-nomodel': 'codex exec "no model given"',
    'w-agy': "agy -p 'summarise' --model gemini-3-pro",
    'w-bayrak': "ssh -F /home/u/bayrak-vcn/.ssh/config bayrak 'claude -p \"do it\" --model opus'",
    'w-bayrak-plain': 'ssh -F /home/u/bayrak-vcn/.ssh/config bayrak uptime',
    'w-arb': 'curl -s http://127.0.0.1:18080/v1/chat/completions -d \'{"model":"arb-coder","messages":[]}\'',
    'w-arbctl': 'python3 ~/arb/arbctl.py restart',
    'w-jev': 'python3 run_jev.py --suite quick',
    'w-jev-port': 'curl -s localhost:18081/decide -d @req.json',
    'w-hetzner': 'curl https://inference.hetzner.com/v1/chat/completions -d \'{"model": "Qwen/Qwen3.6-FP8"}\'',
    'w-hetzner-env': 'curl "$HETZNER_INFERENCE_BASE_URL/chat/completions" -d \'{"model":"Qwen3.8-27B"}\'',
    'w-deepseek': 'python3 tools/review-deepseek.py --diff HEAD~1',
    'w-nvidia': 'curl https://integrate.api.nvidia.com/v1/chat/completions?key=SECRETKEY',
    'w-run': "agentline-run --label 'nightly eval' -- python3 eval.py",
    'w-run-cls': 'agentline-run -- codex exec -m gpt-6-astra "x"',
    'w-bashc': "bash -lc 'agy --model gemini-3-flash -p hi'",
    'w-ssh': 'ssh gpu1 nvidia-smi',
    'w-plain': 'git status --short && git diff --stat',
    'w-escape': 'codex exec -m "gpt\x1b]0;owned\x07\u009b31m" "\x1b[2J prompt"',
}
for agent, cmd in WORKERS.items():
    running(agent, 'Bash', {'command': cmd, 'description': 'SECRETDESC'})
payload('workers', [task(a) for a in WORKERS])

# --- the other tools, and the transcript edge cases ---------------------------
running('t-read', 'Read', {'file_path': '/w/proj/src/parser.py'})
running('t-edit', 'Edit', {'file_path': '/w/proj/README.md', 'old_string': 'SECRETBODY'})
running('t-webfetch', 'WebFetch', {'url': 'https://user:pw@docs.example.com:8443/a/b?token=SECRETQ#f'})
running('t-websearch', 'WebSearch', {'query': 'SECRETQUERY'})
running('t-grep', 'Grep', {'pattern': 'SECRETPAT'})
running('t-agent', 'Agent', {'subagent_type': 'Explore', 'prompt': 'SECRETPROMPT'})
running('t-mcp', 'mcp__github__create_issue', {'title': 'SECRETTITLE'})
running('t-multi', 'Bash', {'command': 'agy --model gemini-3-pro x'}, extra=[('Read', {'file_path': '/w/a.py'})])
running('t-esc', 'Read', {'file_path': '/w/\x1b[31mred\u009b2J\\evil.py'})
running('t-wf', 'Bash', {'command': 'codex exec -m gpt-6-astra x'}, where=wf)
finished('t-done')
# A symlink at the transcript's name — to a real transcript — is not read.
running('t-symtarget', 'Bash', {'command': 'codex exec -m gpt-6-astra x'})
os.symlink(os.path.join(sub, 'agent-t-symtarget.jsonl'), os.path.join(sub, 'agent-t-sym.jsonl'))
# Nor is a FIFO (it would block a plain open).
os.mkfifo(os.path.join(sub, 'agent-t-fifo.jsonl'))
payload('tools', [task(a) for a in ('t-read', 't-edit', 't-webfetch', 't-websearch', 't-grep',
                                    't-agent', 't-mcp', 't-multi', 't-esc', 't-wf', 't-done',
                                    't-sym', 't-fifo', 't-missing')])

# --- task shapes ----------------------------------------------------------
finished('s-completed', end_ago=40)
payload('shapes', [
    task('s-completed', 'completed', startTime=(now - 400) * 1000),
    task('s-completed-nolog', 'completed'),
    task('s-failed', 'failed'),
    task('s-killed', 'killed'),
    task('s-unknown', 'paused'),
    task('s-bare', desc='', label=None, model=None, contextWindowSize=None, tokenCount=None,
         tokenSamples=None, startTime=None, cwd=None, name='bare-name'),
    task('s-effort-num', effort=16000),
    task('s-effort-low', effort='low'),
    task('s-effort-max', effort='max'),
    task('s-effort-xhigh', effort='xhigh', model='claude-opus-5-5'),
    task('s-fable', model='claude-fable-5-1', effort='high'),
    task('s-sonnet', model='claude-sonnet-5'),
    task('s-legacy', model='claude-3-5-sonnet-20241022'),
    task('s-foreign', model='gpt-6-astra'),
    task('s-badmodel', model='x\x1b[31m y'),
    task('s-ctx-hot', tokenCount=170000),
    task('s-ctx-warm', tokenCount=130000),
    task('s-cwd', cwd='/w/other-repo'),
    task('s-esc', desc='fix \x1b[31mred\x1b[0m \u009b2J \\x1b tail‮'),
    task('s-flat', tokenSamples=[5, 5, 5, 5]),
    task('../evil'),
    task('x' * 65),
    'not a task',
    {'id': 's-nostatus'},
    task('s-numstatus', status=3),
])

# --- goldens: a handful of representative rows --------------------------------
running('g-codex', 'Bash', {'command': 'codex exec -m gpt-6-astra "x"'}, ago=125)
running('g-read', 'Read', {'file_path': '/w/proj/agentline.sh'}, ago=3)
finished('g-done', end_ago=20)
payload('golden', [
    task('g-codex', desc='Review the parser changes', effort='low'),
    task('g-read', desc='Survey the install script', model='claude-opus-5-5', effort='xhigh',
         tokenCount=150000, cwd='/w/other'),
    task('g-done', 'completed', desc='Write the changelog entry', model='claude-sonnet-5',
         startTime=(now - 200) * 1000),
    task('g-fail', 'failed', desc='Probe the flaky test', model='claude-fable-5-1', effort=32000),
])

# --- scale ----------------------------------------------------------------
payload('many', [task('m-%02d' % i) for i in range(40)])
for i in range(16):
    running('p-%02d' % i, 'Bash', {'command': 'codex exec -m gpt-6-astra x'}, pad=1 << 20)
payload('perf', [task('p-%02d' % i) for i in range(16)])
running('big', 'Bash', {'command': 'ssh bayrak claude -p x --model sonnet'}, pad=10 << 20)
payload('big', [task('big')])

# --- hostile session id / transcript path: nothing is read ---------------------
payload('badsid', [task('w-codex')], session_id='../' + sid)
payload('relpath', [task('w-codex')], transcript_path='proj/' + sid + '.jsonl')
