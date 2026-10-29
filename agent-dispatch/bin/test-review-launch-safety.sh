#!/usr/bin/env bash
set -eu
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/review-launch-safety.XXXXXX")
[ -n "$TASK_TMP" ] || exit 1
trap 'rm -rf "$TASK_TMP"' EXIT
python3 - "$SELF_DIR" "$TASK_TMP" <<'PY'
import os, pathlib, shutil, signal, subprocess, sys
root, tmp = map(pathlib.Path, sys.argv[1:])
tmp=tmp.resolve()
bin = tmp / 'bin'; bin.mkdir()
repo = tmp / 'repo'; repo.mkdir()
env = dict(os.environ, PATH=str(bin)+':'+os.environ['PATH'], GIT_CONFIG_GLOBAL=str(tmp/'global'), GIT_CONFIG_NOSYSTEM='1', TMPDIR=str(tmp), DISPATCH_SNAPSHOT_TIMEOUT_SECS='15', DISPATCH_MIN_REVIEW_BYTES='0', DISPATCH_REVIEW_REQUIRE_EVIDENCE='0')
(tmp/'global').write_text('[user]\n name = Fixture\n')
real_git = shutil.which('git')
def git(*args):
    subprocess.run([real_git, '-C', str(repo), *args], check=True, stdout=subprocess.DEVNULL)
git('init', '-q'); git('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','initial','--allow-empty')
brief=tmp/'brief'; brief.write_text('Review source\n')
worker=pathlib.Path(os.environ.get('WORKER_UNDER_TEST', str(root/'dispatch-worker')))
failures=[]
def check(ok, message):
    if not ok:
        print('FAIL: '+message, flush=True); failures.append(message)
def stub(name, body):
    path=bin/name; path.write_text('#!/usr/bin/env bash\n'+body+'\n'); path.chmod(0o755)
stub('agy', 'case "${1:-}" in models) printf "%s\\tModel\\n" "${AGY_MODEL_REVIEW_DEFAULT:-gemini-3.1-pro-high}"; exit 0;; agent) exit 0;; esac\ncat >/dev/null\nprintf launched > "$LAUNCH_MARKER"\nprintf "Minor: src/main.sh:1 evidence\\n"')
stub('mktemp', 'if [ "${1:-}" = -t ]; then shift; exec '+shutil.which('mktemp')+' "$TMPDIR/$1"; fi\nexec '+shutil.which('mktemp')+' "$@"')
# Read the published default without duplicating its value.
model=subprocess.check_output(['bash','-c','. "$1"; printf %s "$AGY_MODEL_REVIEW_DEFAULT"','_',str(root/'lib/agy-models.sh')],text=True)
env['AGY_MODEL_REVIEW_DEFAULT']=model; env['LAUNCH_MARKER']=str(tmp/'launched')
env['RUN_ID']='launch-safety-'+str(os.getpid())
stub('codex', 'cat >/dev/null; printf launched > "$LAUNCH_MARKER"')
stub('claude', 'cat >/dev/null; printf launched > "$LAUNCH_MARKER"')
def run(runtime='codex', path=None, extra=None, cwd=None):
    (tmp/'launched').unlink(missing_ok=True)
    e=dict(env); e.update(extra or {})
    p=subprocess.Popen(['tagged-'+e['RUN_ID'],str(path or worker),'--review','--runtime',runtime,'--brief',str(brief),'--workdir',str(cwd or repo)],cwd=str(cwd or repo),env=e,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True,executable=shutil.which('bash'))
    try: out,err=p.communicate(timeout=25)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL); out,err=p.communicate(); check(False, 'temporary path read hung'); return 999,err.decode()
    return p.returncode,err.decode()
def copy_worker(label, transform):
    dest=tmp/label; dest.mkdir(); shutil.copytree(root/'lib',dest/'lib')
    for name in ['review-pin.sh','agy-auth-probe.sh']: shutil.copy(root/name,dest/name)
    path=dest/'dispatch-worker'; path.write_text(transform(worker.read_text())); path.chmod(0o755); return path
# The git failure must be handled before auth or runtime launch.
stub('git', 'case " $* " in *" status "*) exit 128;; esac\nexec '+real_git+' "$@"')
rc,err=run('agy'); check(rc==3 and not (tmp/'launched').exists() and 'dispatch-worker:' in err and 'dirty' in err, 'dirty status 128 must refuse launch with exit 3')
(bin/'git').unlink()
for label, transform, text in [
 ('probe-failure',lambda s:s.replace('review_launch_probe() {','review_launch_probe() {\n  return 3'), 'launch-time git setup could not complete'),
 ('private-failure',lambda s:s.replace('review_private_config() (','review_private_config() (\n  return 3'), 'dispatch-worker: could not build the private global git config')]:
    rc,err=run('agy',copy_worker(label,transform)); check(rc==3 and text in err and not (tmp/'launched').exists(),label+' must refuse with diagnostic')
stub('git', 'case "${1:-}" in clone) sleep 10;; esac\nexec '+real_git+' "$@"')
rc,err=run('agy',extra={'DISPATCH_CLONE_TIMEOUT_SECS':'1'}); check(rc==3 and 'launch-time git setup timed out' in err and 'DISPATCH_CLONE_TIMEOUT_SECS' in err,'clone timeout launch refusal must name clone limit')
(bin/'git').unlink()
# Exact source identity survives trailing whitespace and embedded tag-like lines.
space=tmp/'repo '; shutil.copytree(repo,space)
path=copy_worker('path-check', lambda s:s.replace('review_state_before_runtime() {','review_state_before_runtime() {\n  [ "$REPO_STATE_SRC" = "$WORKDIR" ] || { echo "source identity lost: <$REPO_STATE_SRC> versus <$WORKDIR>" >&2; return 91; }'))
rc,err=run(path=path,cwd=space); check(rc==0 and 'DISPATCH_REVIEW_STATE=clean' in err,'trailing-space source path must remain exact: '+str(rc)+' '+err)
newline=tmp/'repo\npin-top injected'; shutil.copytree(repo,newline)
rc,err=run(path=path,cwd=newline); check(rc==0 and 'DISPATCH_REVIEW_STATE=clean' in err,'newline source path must remain exact')
# Every runtime records launch before a signal can skip its normal tail.
for runtime in ['codex','agy','claude']:
    original=(bin/runtime).read_text()
    # Parent shell processes in pipelines differ; inject a signal from a runtime
    # using the worker pid written before launch in the test-owned worker copy.
    stub(runtime, 'case "${1:-}" in models) printf "%s\\tModel\\n" "$AGY_MODEL_REVIEW_DEFAULT"; exit 0;; esac\ncat >/dev/null\nps -p "$TEST_WORKER_PID" -o command= | grep -Fq "tagged-$RUN_ID" || exit 98\nkill -TERM "$TEST_WORKER_PID"\nsleep 0.2')
    path=copy_worker('signal-'+runtime,lambda s:s.replace('REVIEW_RUNTIME_LAUNCHED=0','REVIEW_RUNTIME_LAUNCHED=0\nexport TEST_WORKER_PID=$$'))
    rc,err=run(runtime,path); check(rc==143 and 'skipped(not-checked)' in err and 'skipped(not-launched)' not in err,runtime+' signal must report not-checked')
    (bin/runtime).write_text(original)
# A reviewer can replace every temporary pathname it can enumerate.
for runtime in ['agy','codex']:
    original=(bin/runtime).read_text()
    body='''case "${1:-}" in models) printf "%s\\tModel\\n" "$AGY_MODEL_REVIEW_DEFAULT"; exit 0;; esac
cat >/dev/null
for file in "$TMPDIR"/dispatch-review.*.md "$TMPDIR"/dispatch-agy-brief.* "$TMPDIR"/dispatch-codex-out.* "$TMPDIR"/dispatch-codex-stdout.*; do
  [ -f "$file" ] || continue
  rm "$file"; mkfifo "$file"
done
printf 'Minor: src/main.sh:1 evidence\\n'
exit 124
'''
    for native_rc in [0,124]:
        stub(runtime,body.replace('exit 124', 'exit '+str(native_rc)))
        rc,err=run(runtime); check(rc in ((10,) if native_rc==0 else (10,124)), runtime+' replaced output and brief FIFOs must finish with mapped verdict (native '+str(native_rc)+')')
    (bin/runtime).write_text(original)
path=copy_worker('merge-failure',lambda s:s.replace("awk 'BEGIN {FS=\"\\t\"} {tag=$1; sub(/^[^\\t]*\\t/, \"\"); if(tag==\"O\" || !seen[$0]) print; seen[$0]=1}'", 'false'))
rc,err=run(path=path); check(rc==3 and 'launch-time git setup could not complete' in err and not (tmp/'launched').exists(),'snapshot merge failure must refuse launch')
# Snapshot sweep and comparison failures have phase-specific outcomes.
stub('find', 'sleep 10')
rc,err=run(extra={'DISPATCH_SNAPSHOT_TIMEOUT_SECS':'1'}); check(rc==3 and 'launch-time git setup timed out' in err,'pre-launch sweep timeout must refuse')
(bin/'find').unlink()
for result in [3,124,125]:
    path=copy_worker('after-'+str(result),lambda s,r=result:s.replace('review_state_snapshot_bounded() {', 'review_state_snapshot_bounded() {\n  if [ "$REVIEW_RUNTIME_LAUNCHED" = 1 ]; then repo_state_nonregular_sweep_memory() { return 3; }; fi') if r==3 else s.replace('review_state_compare_bounded() {','review_state_compare_bounded() {\n  repo_state_run_bounded() { return '+str(r)+'; }'))
    rc,err=run(path=path); check(rc==10 and ('unreadable' in err if result==3 else 'state: drift check could not complete' in err),'after failure '+str(result)+' must fail critical')
# Empty critical diagnostics still count as one failure.
path=copy_worker('count',lambda s:s.replace('review_state_count() {','review_state_count() {\n  REVIEW_STATE_CLASS=2; REVIEW_CHANGES=""'))
rc,err=run(path=path); check(rc==10 and 'critical(1)' in err,'empty critical change list must count one')
# Exercise the actual consumer functions with a status-3 pin helper.
for name in ['coding-dispatch.sh','coding-build-phase.sh']:
    text=(root/name).read_text(); start=text.index('refuse_if_review_pinned() {'); end=text.index('\n}',start)+2
    dest=tmp/('pin-'+name); dest.mkdir(); pin=dest/'review-pin.sh'; pin.write_text('#!/usr/bin/env bash\nexit 3\n'); pin.chmod(0o755)
    p=subprocess.run(['bash','-c',text[start:end]+'\nSCRIPT_DIR=$1\nrefuse_if_review_pinned "$2"','_',str(dest),str(repo)],capture_output=True,text=True,timeout=15)
    check(p.returncode==9 and 'could not determine review pin status' in p.stderr,name+' status 3 must refuse edits')
if failures: sys.exit(1)
print('review launch safety PASS')
PY
