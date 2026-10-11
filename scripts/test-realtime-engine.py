#!/usr/bin/env python3
"""Exercise the bundled host protocol without writing editor changes to source."""
import json, os, pathlib, queue, subprocess, tempfile, threading, time
repo = pathlib.Path(__file__).resolve().parent.parent
engine = repo / '.build/realtime-engine/bin/rtex'
with tempfile.TemporaryDirectory(prefix='texfast-realtime-') as directory:
    root = pathlib.Path(directory)
    source = '\\documentclass{article}\n\\begin{document}\nHello world. A paragraph for live editing.\n\n\\input{chapter}\n\\end{document}\n'
    chapter = 'An included paragraph with Unicode café.\n'
    (root / 'main.tex').write_text(source)
    (root / 'chapter.tex').write_text(chapter)
    env = dict(os.environ, RTEX_TEXDIR=str(repo / '.build/realtime-engine/share/rtex/tex'))
    env['PATH'] = '/Library/TeX/texbin:' + env.get('PATH', '')
    p = subprocess.Popen([str(engine), 'serve', '--project', str(root), '--main', 'main.tex', '--build', str(root / 'cache')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    events = queue.Queue()
    errors = []
    def pump():
        for line in p.stdout:
            events.put(json.loads(line))
    def stderr():
        for line in p.stderr: errors.append(line)
    threading.Thread(target=pump, daemon=True).start()
    threading.Thread(target=stderr, daemon=True).start()
    def send(value):
        print('Send:', value['cmd'], flush=True)
        p.stdin.write(json.dumps(value) + '\n'); p.stdin.flush()
    backlog = []
    def wait(predicate, seconds=30):
        for index, event in enumerate(backlog):
            if predicate(event): return backlog.pop(index)
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try: event = events.get(timeout=min(1, max(.01, deadline-time.monotonic())))
            except queue.Empty:
                if p.poll() is not None: raise AssertionError('Engine exited: ' + ''.join(errors))
                continue
            print('Received:', event.get('reply') or event.get('event'), event.get('result', {}).get('routed'), flush=True)
            if event.get('reply') == 'error': raise AssertionError(event)
            if event.get('event') == 'LayoutUpdate': print('Layout:', event.get('compile'), event.get('convergence'), flush=True)
            if predicate(event): return event
            backlog.append(event)
        raise AssertionError('Timed out: ' + ''.join(errors))
    try:
        layout = wait(lambda e: e.get('event') == 'LayoutUpdate' and e.get('compile', {}).get('state') != 'Failed' and e.get('convergence', {}).get('state') == 'Converged')
        assert layout['pages_total'] == 1, layout
        edit = {'cmd':'edit', 'path':'main.tex', 'start':source.index('world'), 'end':source.index('world')+5, 'text':'realtime'}
        send(edit)
        reply = wait(lambda e: e.get('reply') == 'edit')
        assert reply['result']['routed'] == 'fast', reply
        live = wait(lambda e: e.get('event') == 'ParagraphUpdate' and e['versions']['source_revision'] == reply['result']['source_revision'])
        assert live['status'] == 'ok' and live['dl']['lines'], live
        send({'cmd':'edit', 'path':'chapter.tex', 'start':len(chapter[:chapter.index('café')].encode()), 'end':len(chapter[:chapter.index('café')+4].encode()), 'text':'naïve'})
        included = wait(lambda e: e.get('reply') == 'edit')
        assert included['result']['source_revision'] > reply['result']['source_revision']
        send({'cmd':'request_layout'})
        wait(lambda e: e.get('event') == 'LayoutUpdate' and e['versions']['source_revision'] >= included['result']['source_revision'] and e.get('convergence', {}).get('state') == 'Converged')
        assert (root / 'main.tex').read_text() == source
        assert (root / 'chapter.tex').read_text() == chapter
        send({'cmd':'export_pdf', 'out':str(root/'export.pdf')})
        exported = wait(lambda e: e.get('event') == 'PdfExported')
        assert exported['status']['state'] == 'Ok' and (root/'export.pdf').stat().st_size > 0, exported
        print(f"PASS: initial layout, fast paragraph ({live['timing']['total_us']/1000:.2f} ms), included UTF-8 edit, convergence, clean export, unchanged source")
    finally:
        if p.poll() is None:
            send({'cmd':'quit'}); p.stdin.close()
            try: p.wait(timeout=5)
            except subprocess.TimeoutExpired: p.kill(); p.wait()
