"""Trusted code passed to container python via argv; never loaded from writable /tmp."""
import base64
import json
import hashlib
import time
import os
import stat
import sys

FILE_LIMIT=1024*1024
TOTAL_LIMIT=4*1024*1024
CONTROL_LIMIT=6*1024*1024
MANIFEST_TOTAL_LIMIT=8*1024*1024
MANIFEST_FILE_LIMIT=200
MANIFEST_ENTRY_LIMIT=1000

def safe_name(name):
    if not isinstance(name,str) or not name or len(name.encode())>200 or name.startswith('.') or any(c in name for c in '/\\\x00') or any(ord(c)<32 for c in name):
        raise ValueError('invalid filename')
    lower=name.lower()
    if any(s in lower for s in ('key','secret','credential','token','id_rsa','id_ed25519')) or lower.endswith(('.pem','.p12','.pfx')):
        raise ValueError('credential-like filename denied')
    return name

def validate_files(files):
    if not isinstance(files,list) or len(files)>32:raise ValueError('invalid input files')
    total=0;seen=set();result=[]
    for item in files:
        if not isinstance(item,dict):raise ValueError('invalid input file')
        name=safe_name(item.get('name'));encoded=item.get('base64')
        if name in seen or not isinstance(encoded,str) or len(encoded)>FILE_LIMIT*4//3+4:raise ValueError('invalid input file')
        data=base64.b64decode(encoded,validate=True);total+=len(data)
        if len(data)>FILE_LIMIT or total>TOTAL_LIMIT:raise ValueError('input file limit exceeded')
        seen.add(name);result.append((name,data))
    return result

def open_directory(parent,name):
    return os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent)


def identity(info):
    return [info.st_dev,info.st_ino]

def stable(info):
    return (info.st_dev,info.st_ino,info.st_mode,info.st_nlink,info.st_size,info.st_mtime_ns,info.st_ctime_ns)

def manifest(fd):
    """A partial inventory keeps path presence; missing hashes never imply new files."""
    files=[];visited=0;remaining=MANIFEST_TOTAL_LIMIT
    result={'files':files,'inventoryComplete':True,'hashComplete':True,'checkedAt':time.time(),'rootIdentity':identity(os.fstat(fd))}
    deadline=time.monotonic()+5
    reasons=set()
    def incomplete(reason,inventory=False):
        result['hashComplete']=False
        if inventory:result['inventoryComplete']=False
        reasons.add(reason)
    def walk(directory,prefix,depth):
        nonlocal visited,remaining
        directory_before=os.fstat(directory)
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    visited+=1
                    if visited>MANIFEST_ENTRY_LIMIT or len(files)>=MANIFEST_FILE_LIMIT or time.monotonic()>=deadline:
                        incomplete('inventory_limit',True);return
                    try:safe_name(entry.name)
                    except ValueError:continue
                    path=prefix+entry.name
                    try:info=entry.stat(follow_symlinks=False)
                    except OSError:incomplete('stat_failed',True);continue
                    if stat.S_ISDIR(info.st_mode):
                        if depth>=8:incomplete('depth_limit',True);continue
                        try:child=open_directory(directory,entry.name)
                        except OSError:incomplete('directory_changed',True);continue
                        try:
                            if identity(os.fstat(child))!=identity(info):incomplete('directory_changed',True);continue
                            walk(child,path+'/',depth+1)
                            if identity(os.stat(entry.name,dir_fd=directory,follow_symlinks=False))!=identity(info):incomplete('directory_changed',True)
                        except OSError:incomplete('directory_changed',True)
                        finally:os.close(child)
                        continue
                    item={'path':path,'size':info.st_size};files.append(item)
                    reason=None
                    if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1:reason='unsafe_file'
                    elif info.st_size>TOTAL_LIMIT:reason='file_limit'
                    elif info.st_size>remaining:reason='hash_budget'
                    else:
                        target=None
                        try:
                            target=os.open(entry.name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=directory)
                            before=os.fstat(target)
                            if stable(before)!=stable(info):raise ValueError()
                            digest=hashlib.sha256();count=0
                            while count<info.st_size:
                                if time.monotonic()>=deadline:raise TimeoutError()
                                chunk=os.read(target,min(65536,info.st_size-count))
                                if not chunk:break
                                count+=len(chunk);remaining-=len(chunk)
                                if count>info.st_size or remaining<0:raise ValueError()
                                digest.update(chunk)
                            after=os.fstat(target)
                            named=os.stat(entry.name,dir_fd=directory,follow_symlinks=False)
                            if count!=info.st_size or stable(before)!=stable(after) or stable(after)!=stable(named):raise ValueError()
                            item['sha256']=digest.hexdigest()
                        except (OSError,ValueError):reason='hash_race'
                        finally:
                            if target is not None:os.close(target)
                    if reason:item['reason']=reason;incomplete(reason)
        except OSError:incomplete('inventory_failed',True)
        if stable(directory_before)!=stable(os.fstat(directory)):incomplete('directory_changed',True)
    walk(fd,'',0)
    files.sort(key=lambda item:item['path'])
    if reasons:result['reason']=','.join(sorted(reasons))
    return result

def changes(current,baseline,binding_id,execution_id,turn_id=None):
    previous={item['path']:item for item in baseline['files']} if baseline else {}
    files=[]
    for item in current['files']:
        prior=previous.get(item['path']);change='unknown'
        if baseline and baseline['inventoryComplete'] and current['inventoryComplete'] and item.get('sha256'):
            if prior and prior.get('sha256'):change='unchanged' if prior['sha256']==item['sha256'] else 'modified'
            elif prior is None and baseline['inventoryComplete']:change='new'
        files.append({**item,'change':change})
    return {**current,'files':files,'bindingId':binding_id,'executionId':execution_id,'turnId':turn_id,
            'baselineCapturedAt':baseline.get('checkedAt') if baseline else None,
            'baselineInventoryComplete':baseline.get('inventoryComplete',False) if baseline else False,
            'baselineHashComplete':baseline.get('hashComplete',False) if baseline else False,
            'baselineReason':baseline.get('reason') if baseline else 'no_runtime_baseline'}

def _perform(request,root):
    method=request.get('method');fd=os.dup(root) if isinstance(root,int) else os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
        if method=='manifest':return manifest(fd)
        if method=='import':
            files=validate_files(request.get('files'))
            for name,data in files:
                target=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=fd)
                with os.fdopen(target,'wb') as stream:stream.write(data)
            return {'imported':len(files)}
        if method=='export':
            path=request.get('path')
            if not isinstance(path,str) or len(path)>2048:raise ValueError('invalid artifact path')
            parts=path.split('/')
            if len(parts)>9:raise ValueError('artifact depth exceeded')
            for part in parts:safe_name(part)
            current=os.dup(fd)
            try:
                for part in parts[:-1]:
                    next_fd=open_directory(current,part);os.close(current);current=next_fd
                target=os.open(parts[-1],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=current)
                with os.fdopen(target,'rb') as stream:
                    info=os.fstat(stream.fileno())
                    if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1 or info.st_size>TOTAL_LIMIT:raise ValueError('invalid artifact')
                    data=stream.read(TOTAL_LIMIT+1)
                    if len(data)>TOTAL_LIMIT or len(data)!=info.st_size or stable(info)!=stable(os.fstat(stream.fileno())) or stable(info)!=stable(os.stat(parts[-1],dir_fd=current,follow_symlinks=False)):raise ValueError('artifact changed during read')
                # Rewalk the requested relative path from the pinned root. A
                # renamed child descriptor must not confirm bytes for a new child.
                verify=os.dup(fd)
                try:
                    for part in parts[:-1]:
                        next_fd=open_directory(verify,part);os.close(verify);verify=next_fd
                    if stable(info)!=stable(os.stat(parts[-1],dir_fd=verify,follow_symlinks=False)):raise ValueError('artifact path changed during read')
                finally:os.close(verify)
                return {'name':parts[-1],'base64':base64.b64encode(data).decode()}
            finally:os.close(current)
        if method=='artifacts':
            files=[];visited=0
            def walk(directory,prefix,depth):
                nonlocal visited
                if depth>8:return
                with os.scandir(directory) as entries:
                    for entry in entries:
                        visited+=1
                        if visited>1000 or len(files)>=200:raise ValueError('artifact listing limit exceeded')
                        try:safe_name(entry.name)
                        except ValueError:continue
                        info=entry.stat(follow_symlinks=False)
                        path=prefix+entry.name
                        if stat.S_ISREG(info.st_mode) and info.st_nlink==1 and info.st_size<=TOTAL_LIMIT:files.append({'path':path,'size':info.st_size})
                        elif stat.S_ISDIR(info.st_mode):
                            child=open_directory(directory,entry.name)
                            try:walk(child,path+'/',depth+1)
                            finally:os.close(child)
            walk(fd,'',0)
            return {'files':sorted(files,key=lambda f:f['path'])}
        raise ValueError('unknown workspace operation')
    finally:os.close(fd)

def perform(request,root='/tmp/workspace'):
    fd=os.dup(root) if isinstance(root,int) else os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
        pinned=identity(os.fstat(fd))
        expected=request.get('expectedRootIdentity')
        if expected is not None and expected!=pinned:raise ValueError('workspace root changed')
        result=_perform(request,fd)
        current=os.dup(root) if isinstance(root,int) else os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        try:
            if identity(os.fstat(current))!=pinned:raise ValueError('workspace root changed during read')
        finally:os.close(current)
        if request.get('includeIdentity') is True:result['rootIdentity']=pinned
        return result
    finally:os.close(fd)

if __name__=='__main__':
    try:
        raw=sys.stdin.buffer.read(CONTROL_LIMIT+1)
        if len(raw)>CONTROL_LIMIT:raise ValueError('input limit exceeded')
        print(json.dumps(perform(json.loads(raw)),separators=(',',':')))
    except Exception:
        print(json.dumps({'error':'workspace operation denied or failed'}));sys.exit(1)
