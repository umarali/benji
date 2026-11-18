"""Replayable offline interface checks. Inputs are prebuilt; never downloads or opens the GUI."""
import argparse,hashlib,json,os,queue,shutil,struct,subprocess,threading,time,tempfile
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
parser=argparse.ArgumentParser(description='Headless checks that TEMPORARILY MODIFY a disposable app copy. Never use an installed app.')
parser.add_argument('--bundle',required=True);parser.add_argument('--probe',required=True);parser.add_argument('--output-dir',required=True)
args=parser.parse_args()
P=Path(args.output_dir).resolve();P.mkdir(parents=True);(P/'evidence').mkdir()
app=Path(args.bundle).resolve()
probe=Path(args.probe).resolve()
passed=[]
def check(name, condition):
    if not condition: raise AssertionError(name)
    passed.append(name);print('PASS',name,flush=True)
def call(*args,env=None,input=None):
    return subprocess.run([str(probe),*map(str,args)],env=env or os.environ,capture_output=True,input=input,text=True,timeout=35)
def describe(entry,*args):
    result=call('describe',app,entry,*args);assert result.returncode==0,result.stderr
    return json.loads(result.stdout)
def tree():
    out={}
    for f in sorted(app.rglob('*')):
        name=str(f.relative_to(app))
        out[name]=('link:'+os.readlink(f) if f.is_symlink() else hashlib.sha256(f.read_bytes()).hexdigest() if f.is_file() else 'directory')+':'+oct(f.lstat().st_mode & 0o777)
    return out
before=tree()
r=call('cache-check',app)
check('successful Swift cache invalidates bootstrap runtime and manifest changes',r.returncode==0 and json.loads(r.stdout)['cache_invalidations']==3)
# Refuse unsafe locations before any registration is written. No volume is mounted.
translocated=P/'AppTranslocation/fixture/Benji.app';translocated.mkdir(parents=True)
for location in (translocated,Path('/System')):
    fake=Path(tempfile.mkdtemp(prefix='refused-home-',dir=P))
    r=call('register',location,fake)
    check('registration refuses '+('translocation path' if location==translocated else 'real read-only system volume'),r.returncode==78 and 'unsupportedDistributionLocation' in r.stderr and not list(fake.rglob('*')))

env=dict(os.environ,PATH='/nonexistent',PYTHONHOME='/invalid',PYTHONPATH='/invalid',PYTHONSTARTUP='/invalid',BENJI_DIR='/invalid',BENJI_PROVIDER='ollama',BENJI_MODEL='fake')
for k in list(env):
    if k.endswith(('_KEY','_TOKEN','_SECRET')) or 'PROXY' in k.upper(): env.pop(k)
check('distribution locator ignores BENJI_DIR',json.loads(call('locate',app,env=env).stdout)['directory']==str(app/'Contents/Resources/engine'))
d=json.loads(call('describe',app,'engine','--version',env=env).stdout)
check('absolute Python and isolated bootstrap; no shell or source root',d['executable'].endswith('bin/python3.12') and d['arguments'][:3]==['-I','-B','-u'] and d['directory']==str(app/'Contents/Resources/engine'))
check('Python overrides scrubbed and documented tool PATH',not any(k.startswith('PYTHON') for k in d['environment']) and 'BENJI_DIR' not in d['environment'] and d['environment']['PATH']=='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin')
for entry,args,exitcode,needle,input in [('engine',['--version'],0,'Benji 0.1.0',None),('engine',['--print-provider'],0,'provider',None),('engine',['--diagnose','--hours','24'],0,'Benji',None),('model-setup',[],0,'ok','null'),('remote',['--help'],0,'--port',None),('engine',['--transcribe','/missing.wav'],2,'key',None)]:
    r=call('launch',app,entry,*args,env=env,input=input)
    check('launch '+entry+' '+str(args),r.returncode==exitcode and needle.lower() in (r.stdout+r.stderr).lower())
# Optional Kokoro retains its separately managed interpreter. No optional dependencies are claimed.
optional_env={**env,'DISTRIBUTION_PROBE_OPTIONAL_PYTHON':d['executable']}
r=call('launch',app,'tts',env=optional_env)
check('optional TTS reaches engine without fake bundled dependencies',r.returncode==2 and 'kokoro' in (r.stdout+r.stderr).lower())
# Closed bootstrap rejects arbitrary module/import-root requests.
command=[d['executable'],*d['arguments'][:4],'os']
r=subprocess.run(command,env=env,text=True,capture_output=True,timeout=15)
check('bootstrap entry points closed',r.returncode==78 and 'unknown' in r.stderr)
# Real fake provider over loopback. Protocol lines only on stdout.
class Fake(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_POST(self):
        request=json.loads(self.rfile.read(int(self.headers['content-length'])))
        body=json.dumps({'choices':[{'message':{'role':'assistant','content':'offline typed reply'}}]}).encode()
        self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
server=ThreadingHTTPServer(('127.0.0.1',0),Fake);threading.Thread(target=server.serve_forever,daemon=True).start()
try:
    work=P/'disposable-work';work.mkdir(exist_ok=True)
    fake_env={**env,'BENJI_BASE_URL':f'http://127.0.0.1:{server.server_port}/v1','BENJI_MODEL':'fake','BENJI_PROVIDER':'openai','OPENAI_API_KEY':'unused-local-fixture','BENJI_WORKDIR':str(work),'BENJI_STREAM':'0'}
    process=subprocess.Popen([str(probe),'launch',str(app),'engine','--serve'],env=fake_env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    events=queue.Queue()
    def reader():
        for line in process.stdout: events.put(json.loads(line))
    threading.Thread(target=reader,daemon=True).start()
    def send_until(request,kind):
        process.stdin.write(json.dumps(request)+'\n');process.stdin.flush();out=[];end=time.monotonic()+25
        while time.monotonic()<end:
            event=events.get(timeout=25);out.append(event)
            if event.get('type')==kind:return out
        raise AssertionError('protocol timeout')
    hello=send_until({'type':'hello','protocol':1},'ready')
    check('bundled engine hello and model identity',hello[-1].get('model')=='fake')
    reply=send_until({'type':'send','id':'typed1','text':'hello offline'},'done')
    check('typed request through real serve protocol and disposable storage',any(e.get('type')=='answer' and e.get('text')=='offline typed reply' for e in reply))
    process.stdin.close();process.wait(timeout=15)
    check('engine EOF exits cleanly',process.returncode==0)
finally: server.shutdown();server.server_close()
# Native host launch and byte framing; no real browser or real profile is opened.
home=Path(tempfile.mkdtemp(prefix="fake browser's home-",dir=P))
r=call('register',app,home,env=env);check('native registration with spaces/apostrophes',r.returncode==0)
registration=json.loads(r.stdout);launcher=Path(registration['launcher']);manifest=Path(registration['manifest'])
r=subprocess.run([str(launcher),'chrome-extension://'+'a'*32+'/'],env=env,capture_output=True,timeout=15)
check('native stdout has exactly one length-prefixed refusal frame',r.returncode==2 and len(r.stdout)>4 and struct.unpack('<I',r.stdout[:4])[0]==len(r.stdout)-4 and json.loads(r.stdout[4:])['type']=='unavailable')
script=launcher.read_bytes();launcher.write_bytes(script.replace(b'bootstrap.py',b'old-bootstrap.py'))
check('stale launcher remains owned but is not current',json.loads(call('owned',app,home,env=env).stdout)['owned'] and not json.loads(call('current',app,home,env=env).stdout)['current'])
check('explicit repair refreshes existing registration',call('register',app,home,env=env).returncode==0 and launcher.read_bytes()==script)
moved=P/"second space's location/Benji.app";moved.parent.mkdir(exist_ok=True);app.rename(moved);app=moved
check('moving bundle keeps opt-in ownership and invalidates old launcher',json.loads(call('owned',app,home,env=env).stdout)['owned'] and not json.loads(call('current',app,home,env=env).stdout)['current'])
check('startup repair refreshes only existing opted-in registrations',call('repair',app,home,env=env).returncode==0 and json.loads(call('current',app,home,env=env).stdout)['current'])
# Descriptor paths now refer to the moved bundle for the fail-closed checks below.
d=json.loads(call('describe',app,'engine','--version',env=env).stdout)
foreign=b'{"name":"somebody.else"}\n';manifest.write_bytes(foreign)
check('foreign manifest never overwritten',call('register',app,home,env=env).returncode!=0 and manifest.read_bytes()==foreign)
call('unregister',app,home,env=env);check('foreign manifest never uninstalled',manifest.read_bytes()==foreign)
# A changed non-critical listed file is rejected by every bootstrap entry, even with a cached Swift gate.
notice=app/'Contents/Resources/Notices/Benji-LICENSE.txt';saved=notice.read_bytes();notice.write_bytes(saved+b'\ncorrupt')
try:
    d=json.loads(call('describe',app,'engine','--version',env=env).stdout)
    for entry in ('engine','remote','model-setup','native-host','tts'):
        r=subprocess.run([d['executable'],*d['arguments'][:4],entry,'--version'],env=env,capture_output=True,timeout=15)
        check('full bootstrap validation rejects corruption for '+entry,r.returncode==78 and not r.stdout and b'checksum mismatch' in r.stderr)
finally:notice.write_bytes(saved)
# Corrupt manifest and missing runtime fail before engine launch, with no PATH fallback.
m=app/'Contents/Resources/distribution.json';original=m.read_bytes();m.write_text('{}')
try:
    check('invalid manifest fails closed in Swift',call('launch',app,'engine','--version',env=env).returncode==78)
    r=subprocess.run([d['executable'],*d['arguments']],env=env,capture_output=True,timeout=15)
    check('invalid manifest fails closed in native/bootstrap route',r.returncode==78 and not r.stdout)
finally:m.write_bytes(original)
python=app/'Contents/Frameworks/BenjiPython.framework/Versions/A/BenjiPython';missing=python.with_name('missing-python');python.rename(missing)
try:check('missing runtime fails closed without fallback',call('launch',app,'engine','--version',env=env).returncode==78)
finally:missing.rename(python)
check('all launch exercises leave bundle bytes, links and modes unchanged',tree()==before)
verify=subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],capture_output=True,text=True)
check('relocated complete distribution passes strict verification',verify.returncode==0)
(P/'evidence/distribution-checks.json').write_text(json.dumps({'passed':passed,'count':len(passed),'bundle':str(app)},indent=2)+'\n')
print('TOTAL',len(passed),flush=True)

(P/'bundle.txt').write_text(str(app)+'\n')
