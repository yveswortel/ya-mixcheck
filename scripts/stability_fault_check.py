#!/usr/bin/env python3
"""Native faults in owned processes/TMPDIRs and an expendable 64 MiB volume.

Does not disconnect networking, fill the system volume or kill existing apps.
Requires normal macOS NSFileCoordinator / disk-image permissions.
"""
import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from performance_release_check import fixture, sha

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,default=ROOT/'build/YA-MixCheck.app/Contents/MacOS/YA-MixCheck')
    parser.add_argument('--output',type=Path,default=ROOT/'Validation/stability-20261027/native-faults.json')
    parser.add_argument('--decode-source',type=Path)
    args=parser.parse_args();app=args.app.resolve();checks=[];probes=[]
    result={'appSHA256':sha(app),'checks':checks,'probes':probes}
    def check(name,passed,detail=None):checks.append(dict(name=name,passed=bool(passed),detail=detail))
    def wait_for(fn,timeout=8):
        end=time.monotonic()+timeout
        while time.monotonic()<end:
            value=fn()
            if value:return value
            time.sleep(.025)
        return None
    def alive(pid):
        r=subprocess.run(['/bin/ps','-o','stat=','-p',str(pid)],capture_output=True,text=True)
        return bool(r.stdout.strip()) and not r.stdout.strip().startswith('Z')
    with tempfile.TemporaryDirectory(prefix='ya-stability-fault-',dir='/private/tmp') as directory:
        root=Path(directory);source=root/'source.wav';fixture(source,30,48000);source_hash=sha(source)
        scratch=root/'scratch';scratch.mkdir();env=dict(os.environ,YA_MIXCHECK_STABILITY_TMP=str(scratch))
        decode=None
        if args.decode_source:
            decode_hash=sha(args.decode_source);decode=root/'decode.flac';shutil.copyfile(args.decode_source,decode)
        def probe(mode,src=source,environment=env,timeout=30):
            report=root/('report-'+str(len(probes))+'.json')
            run=subprocess.run([str(app),'--stability-probe',mode,str(src),str(report)],env=environment,capture_output=True,text=True,timeout=timeout)
            if run.returncode or not report.exists():raise RuntimeError(run.stderr[-1000:])
            data=json.loads(report.read_text());probes.append(data);return data
        for mode,src in [('prepare',source),('eq',source)]+([('decode',decode)] if decode else []):
            data=probe(mode,src)
            check(mode+' baseline uses isolated TMPDIR',Path(data['temporaryRoot']).resolve()==scratch.resolve())
            check(mode+' baseline succeeds and cleans cache',data['ok'] and not data['newTemporaryEntries'],data)

        # A real cross-process NSFileCoordinator writer holds the reader. Kill
        # only the owner launched here, then observe production helper watchdog.
        lock_report=root/'lock.json';hold_report=root/'held.json'
        lock_log=(root/'lock.log').open('w');owner_log=(root/'owner.log').open('w')
        locker=subprocess.Popen([str(app),'--stability-probe','coordinate',str(source),str(lock_report)],env=env,stdout=lock_log,stderr=lock_log)
        owner=None
        try:
            if not wait_for(lock_report.exists):raise RuntimeError('Native coordination lock was not acquired')
            owner=subprocess.Popen([str(app),'--stability-probe','hold',str(source),str(hold_report)],env=env,stdout=owner_log,stderr=owner_log)
            def helper():
                r=subprocess.run(['/bin/ps','-axo','pid=,ppid=,args='],capture_output=True,text=True)
                for line in r.stdout.splitlines():
                    fields=line.strip().split(None,2)
                    if len(fields)==3 and fields[1]==str(owner.pid) and '--prepare-input-worker' in fields[2]:return int(fields[0])
            child=wait_for(helper)
            check('production helper observed under owned parent',child is not None)
            check('read genuinely blocked by native coordinator',not hold_report.exists() and owner.poll() is None)
            owned=list(scratch.glob('ya-mixcheck-input-*'))
            check('in-flight snapshot registered',len(owned)==1)
            # Active lease must prevent recovery even for an old directory.
            for path in owned:os.utime(path,(time.time()-600,time.time()-600))
            probe('recover',scratch)
            check('another process cannot recover live snapshot',bool(owned) and all(p.exists() for p in owned))
            began=time.monotonic();owner.kill();owner.wait(timeout=5)
            exited=bool(child) and wait_for(lambda:not alive(child),timeout=4)
            check('helper exits after owner SIGKILL during coordination',exited,{'seconds':time.monotonic()-began})
            probe('recover',scratch)
            check('abandoned snapshot recovered after owner dies',bool(owned) and all(not p.exists() for p in owned))
        finally:
            for process in [owner,locker]:
                if process and process.poll() is None:process.kill();process.wait(timeout=5)
            lock_log.close();owner_log.close()
        check('preparation recovers after killed process',probe('prepare')['ok'])

        # The host disk is never filled. Refuse to write the filler unless the
        # mount is an actual small separate volume created by this invocation.
        image=root/'scratch.dmg';mount=root/'full-volume';mount.mkdir();mounted=False
        try:
            subprocess.run(['/usr/bin/hdiutil','create','-size','64m','-fs','HFS+','-volname','YA-Stability-Disposable',str(image)],check=True,capture_output=True,timeout=60)
            subprocess.run(['/usr/bin/hdiutil','attach','-nobrowse','-noautoopen','-mountpoint',str(mount),str(image)],check=True,capture_output=True,timeout=30);mounted=True
            usage=shutil.disk_usage(mount)
            if not os.path.ismount(mount) or usage.total>128*1024**2 or os.stat(mount).st_dev==os.stat(root).st_dev:
                raise RuntimeError('Disposable-volume safety check failed')
            volume_tmp=mount/'tmp';volume_tmp.mkdir()
            filler=mount/'filler.bin'
            target=max(0,shutil.disk_usage(mount).free-256*1024)
            with filler.open('wb',buffering=0) as f:
                while target>0:
                    block=min(1<<20,target);f.write(b'\0'*block);target-=block
                os.fsync(f.fileno())
            result['fullVolume']={'totalBytes':usage.total,'freeBeforeProbe':shutil.disk_usage(mount).free}
            volume_env=dict(os.environ,YA_MIXCHECK_STABILITY_TMP=str(volume_tmp))
            for mode,src in [('prepare',source),('eq',source)]+([('decode',decode)] if decode else []):
                data=probe(mode,src,volume_env)
                check(mode+' low-space test stayed on disposable volume',Path(data['temporaryRoot']).resolve()==volume_tmp.resolve())
                check(mode+' reports failure without publishing output',not data['ok'],data)
                check(mode+' low-space failure leaves no cache',not data['newTemporaryEntries'])
            filler.unlink()
            check('same volume recovers when space is freed',probe('prepare',source,volume_env)['ok'])
        finally:
            if mounted:subprocess.run(['/usr/bin/hdiutil','detach',str(mount)],check=True,capture_output=True,timeout=30)
        check('generated source unchanged',sha(source)==source_hash)
        if decode:
            check('professional reference and private copy unchanged',sha(decode)==decode_hash and sha(args.decode_source)==decode_hash)
    result['passed']=all(x['passed'] for x in checks)
    result['limitations']=['Fault isolation uses a small HFS+ disk image; not a system-disk-full test.','Coordination stall is real local macOS coordination, not an offline iCloud download.','Crash recovery uses controlled directory aging to exercise the existing five-minute threshold.']
    args.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'passed':result['passed'],'checks':len(checks),'failures':[x for x in checks if not x['passed']]}))
    return 0 if result['passed'] else 1

if __name__=='__main__':raise SystemExit(main())
