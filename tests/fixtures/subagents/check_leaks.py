"""The leak corpus check: no planted secret reaches a subagent row or an
agentline-run label.

  check_leaks.py <bash> <agentline-subagents.sh> <leak-corpus.json> <workdir>

leak-corpus.json is fully synthetic: 399 invented shell commands with 771
planted fake keys, names, hosts and paths (review of J9b, stage J9c). Each
command is shown to agentline-subagents.sh two ways, as in real use:

  render    a running Bash tool_use in a subagent transcript, 32 tasks to a
            payload (the most one tick renders), through the real script;
  classify  split into argv (shlex), the way agentline-run hands its CMD to
            `--classify`. This runs the script's embedded program in this
            interpreter, once per command: 399 python3 starts would cost
            more than the rest of the suite's subagent tests together, and
            the bash around it only picks the mode.

A leak is a planted value, or any 6-character slice of it that is not a
plain lowercase word, in the output. One exception: the basename of a
planted *.py or *.sh path (etl.py of /home/x/clients/zeta/etl.py) is how
a script is meant to be named on a row, so that token alone is not counted.
A directory, or any other part of the path, is. Nothing is executed.
Prints one summary line; exits 1 on any leak."""
import io, json, os, re, shlex, subprocess, sys

bash, script, corpus_path, work = sys.argv[1:5]
corpus = json.load(open(corpus_path, encoding='utf-8'))
SGR = re.compile(r'\x1b\[[0-9;]*m|\x1b\]8;;[^\x07]*\x07')
SCRIPT = re.compile(r'[A-Za-z0-9._-]{1,32}\.(?:py|sh)')

def leaks(text, planted):
    hits = []
    for p in planted:
        t = text
        b = p.rsplit('/', 1)[-1]
        if '/' in p and SCRIPT.fullmatch(b):
            t = re.sub(r'(?<![A-Za-z0-9._/-])' + re.escape(b) + r'(?![A-Za-z0-9._/-])', ' ', t)
        if p in t:
            hits.append(p)
            continue
        for i in range(max(1, len(p) - 5)):
            s = p[i:i + 6]
            if len(s) == 6 and s in t and not re.fullmatch(r'[a-z]+', s):
                hits.append(p + ' ~' + s)
                break
    return hits

# --- render: the real script, 32 tasks a payload ------------------------------
home = os.path.join(work, 'home')
proj = os.path.join(home, '.claude', 'projects', '-p')
sid = '0f0e0d0c-aaaa-bbbb-cccc-000000000001'
sub = os.path.join(proj, sid, 'subagents')
os.makedirs(sub)
os.chmod(work, 0o700)
env = {'HOME': home, 'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'LC_ALL': 'C.UTF-8',
       'AGENTLINE_NOW': '1790000000'}
render = classify = 0
examples = []
for start in range(0, len(corpus), 32):
    batch = list(enumerate(corpus[start:start + 32], start))
    tasks = []
    for n, it in batch:
        aid = 'a%016x' % n
        line = {'type': 'assistant', 'timestamp': '2026-09-28T00:00:00.000Z',
                'message': {'role': 'assistant', 'content': [
                    {'type': 'tool_use', 'id': 'toolu_%d' % n, 'name': 'Bash',
                     'input': {'command': it['cmd'], 'description': 'run'}}]}}
        with open(os.path.join(sub, 'agent-%s.jsonl' % aid), 'w', encoding='utf-8') as f:
            f.write(json.dumps(line) + '\n')
        tasks.append({'id': aid, 'status': 'running', 'description': 'fuzz', 'startTime': 1789999000000,
                      'model': 'claude-opus-5-5', 'contextWindowSize': 1000000, 'tokenCount': 12000})
    payload = {'session_id': sid, 'transcript_path': os.path.join(proj, sid + '.jsonl'), 'cwd': '/w',
               'columns': 200, 'tasks': tasks}
    r = subprocess.run([bash, script], input=json.dumps(payload).encode(), capture_output=True,
                       env=env, cwd=work, timeout=60)
    rows = {}
    for ln in r.stdout.decode('utf-8', 'replace').splitlines():
        o = json.loads(ln)
        rows[o['id']] = SGR.sub('', o['content'])
    for n, it in batch:
        out = rows.get('a%016x' % n, '')
        if '→' not in out:
            render += 1  # every task is running a Bash call: its row must say so
            examples.append(('render: no activity', it['cmd'][:60], out[:80]))
            continue
        h = leaks(out, it['planted'])
        if h:
            render += 1
            examples.append(('render', out[:120], h[:2]))

# --- classify: the embedded program, in this interpreter ---------------------
src = open(script, encoding='utf-8').read()
prog = compile(src.split("<<'PYEOF'\n", 1)[1].split('\nPYEOF\n', 1)[0], script, 'exec')
for it in corpus:
    try:
        argv = shlex.split(it['cmd'], comments=False)
    except ValueError:
        continue
    if not argv:
        continue
    buf, saved = io.StringIO(), (sys.argv, sys.stdout)
    sys.argv, sys.stdout = ['agentline-subagents', 'classify', ''] + argv, buf
    try:
        exec(prog, {'__name__': '__agentline__'})
    except SystemExit:
        pass
    finally:
        sys.argv, sys.stdout = saved
    h = leaks(buf.getvalue(), it['planted'])
    if h:
        classify += 1
        examples.append(('classify', buf.getvalue().strip()[:80], h[:2]))

print('%d commands | render leaks: %d | classify (agentline-run label) leaks: %d'
      % (len(corpus), render, classify))
for e in examples[:12]:
    print('  %r' % (e,))
sys.exit(1 if render or classify else 0)
