"""Trusted code passed to container python via argv; never loaded from writable /tmp."""
import base64
import json
import os
import stat
import sys

FILE_LIMIT=1024*1024
TOTAL_LIMIT=4*1024*1024
CONTROL_LIMIT=6*1024*1024

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

def perform(request,root='/tmp/workspace'):
    method=request.get('method');fd=os.dup(root) if isinstance(root,int) else os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
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
                    if len(data)>TOTAL_LIMIT:raise ValueError('artifact limit exceeded')
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

if __name__=='__main__':
    try:
        raw=sys.stdin.buffer.read(CONTROL_LIMIT+1)
        if len(raw)>CONTROL_LIMIT:raise ValueError('input limit exceeded')
        print(json.dumps(perform(json.loads(raw)),separators=(',',':')))
    except Exception:
        print(json.dumps({'error':'workspace operation denied or failed'}));sys.exit(1)
