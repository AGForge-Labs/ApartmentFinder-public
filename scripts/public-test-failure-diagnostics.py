#!/usr/bin/env python3
"""Reconstruct bounded public synthetic failure scalars; never upload attachments.

Caller retains the original xcodebuild status and owns simulator cleanup.
Only community-area-controls-regression's exact six identities are admitted.
Unknown schemas, commands and report associations produce fixed status tokens.
"""
import argparse
import contextlib
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import plistlib
import re
import signal
import stat
import subprocess
import sys
import threading
import time

APP = 'dev.galaxybigbird.ApartmentFinder'
RUNNER = 'dev.galaxybigbird.ApartmentFinderUITests.xctrunner'
EXPECTED = (
 'ApartmentFinderTests/PublicCatalogBundleStoreTests/testProductionAppBundleLoadsReviewedPublicCatalogWithoutMapImport',
 'ApartmentFinderTests/PublicCatalogBundleStoreTests/testSavedPackSupplementPreservesGenerationAndPersonalBytesAcrossReopen',
 'ApartmentFinderUITests/CommunityMapControlsTests/testPausedControlsStayCompactAndKeepTheirActions',
 'ApartmentFinderUITests/CommunityMapControlsTests/testLyricAndTrendShowTheirCommunityAreasWithoutInventingDoors',
 'ApartmentFinderUITests/OnTracFlowTests/testSourceUnitPinAppearsOnMapAfterOnTracImport',
 'ApartmentFinderUITests/MapAppearanceTests/testMapTypePersistsAcrossDoorReviewDeliveryAdvanceAndRelaunch',
)
MAX_INPUT = 1024 * 1024
MAX_OUTPUT = 65536
DEVICE_RE = re.compile(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\Z')
IMAGES = frozenset(('ApartmentFinder','ApartmentFinderUITests-Runner','MapKit','VectorKit','SwiftUI',
 'SwiftUICore','UIKitCore','Foundation','CoreFoundation','AttributeGraph','QuartzCore','GraphicsServices',
 'XCTest','XCTestCore','XCTAutomationSupport','AccessibilityUtilities','libswiftCore.dylib',
 'libsystem_kernel.dylib','libsystem_pthread.dylib','libsystem_c.dylib','libdispatch.dylib','libobjc.A.dylib'))
EXCEPTIONS = frozenset(('EXC_BAD_ACCESS','EXC_CRASH','EXC_BREAKPOINT','EXC_RESOURCE','EXC_GUARD',
 'EXC_BAD_INSTRUCTION','EXC_SOFTWARE','EXC_ARITHMETIC','EXC_EMULATION','EXC_SYSCALL','EXC_MACH_SYSCALL'))
SIGNALS = frozenset(('SIGABRT','SIGSEGV','SIGBUS','SIGTRAP','SIGILL','SIGKILL','SIGTERM','SIGFPE','SIGSYS','SIGXCPU'))
NAMESPACES = frozenset(('SIGNAL','FRONTBOARD','RUNNINGBOARD','WATCHDOG','JETSAM','CODESIGNING',
 'SPRINGBOARD','DYLD','LIBSYSTEM','GUARD','RESOURCE','ASSERTIOND','TCC'))

def _unique(pairs):
    result = {}
    for key,value in pairs:
        if key in result:
            raise ValueError()
        result[key] = value
    return result

def _bad_constant(_):
    raise ValueError()

def _json(raw):
    return json.loads(raw, object_pairs_hook=_unique, parse_constant=_bad_constant)

def _number(value, low=0, high=2**64-1):
    return value if type(value) in (int,float) and math.isfinite(value) and low <= value <= high else None

def _epoch(value):
    if type(value) in (int,float):
        return _number(value, 1_000_000_000, 4_200_000_000)
    if type(value) is str and len(value) <= 48:
        try:
            normalized=re.sub(r'\s([+-]\d{2})(\d{2})$',r'\1:\2',value.replace('Z','+00:00'))
            instant = datetime.fromisoformat(normalized)
            if instant.tzinfo is not None:
                return _number(instant.timestamp(),1_000_000_000,4_200_000_000)
        except ValueError:
            pass
    return None

def _utc(value):
    return datetime.fromtimestamp(value, timezone.utc).isoformat().replace('+00:00','Z')

def _symbol(value):
    # A symbol-looking string is still untrusted. Emit only finite exact literals.
    allowed=('abort','__abort_with_payload','__pthread_kill','_pthread_kill','objc_exception_throw',
      'swift_dynamicCastFailure','_assertionFailure','dispatch_assert_queue_fail','__assert_rtn',
      'pthread_kill','__exceptionPreprocess','swift_unexpectedError','-[MKMapView setCamera:]')
    return value if type(value) is str and value in allowed else None

def _walk(value, child_keys=None, limit=8192, depth=32):
    stack=[(value,0)]; count=0
    while stack:
        node,level=stack.pop();count+=1
        if count > limit or level > depth:
            raise ValueError()
        if isinstance(node,dict):
            yield node
            children=node.values() if child_keys is None else (node[k] for k in child_keys if k in node)
            stack.extend((x,level+1) for x in children if isinstance(x,(dict,list)))
        elif isinstance(node,list):
            stack.extend((x,level+1) for x in reversed(node) if isinstance(x,(dict,list)))

def _identity(value, selected):
    if type(value) is not str or len(value)>220:
        return None
    value=value.removesuffix('()')
    matches=[item for item in selected if item==value or item.endswith('/'+value)]
    return matches[0] if len(matches)==1 else None

def read_regular(path, limit=MAX_INPUT):
    """No-follow every ancestor on POSIX; bounded regular-file reads only."""
    try:
        path=Path(path)
        if not path.is_absolute() or '..' in path.parts:
            return 'invalid',None
        with contextlib.ExitStack() as handles:
            if os.name=='posix':
                flags=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW
                directory=os.open(path.anchor,flags);handles.callback(os.close,directory)
                for part in path.parts[1:-1]:
                    directory=os.open(part,flags,dir_fd=directory);handles.callback(os.close,directory)
                fd=os.open(path.name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=directory)
            else:
                # Windows fixture support. Production target is the POSIX path above.
                for parent in [*reversed(path.parents),path]:
                    info=parent.lstat()
                    if stat.S_ISLNK(info.st_mode) or getattr(info,'st_file_attributes',0)&0x400:
                        return 'invalid',None
                fd=os.open(path,os.O_RDONLY|os.O_BINARY)
            handles.callback(os.close,fd)
            info=os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                return 'invalid',None
            if info.st_size>limit:
                return 'oversize',None
            data=bytearray()
            while len(data)<=limit:
                chunk=os.read(fd,min(8192,limit+1-len(data)))
                if not chunk:
                    break
                data.extend(chunk)
            return ('oversize',None) if len(data)>limit else ('available',bytes(data))
    except FileNotFoundError:
        return 'missing',None
    except (OSError,ValueError):
        return 'invalid',None

def _directory(path):
    """Return a no-follow directory fd; caller closes it. No recursive walking."""
    flags=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW
    opened=[]
    try:
        path=Path(path)
        if not path.is_absolute() or '..' in path.parts:
            raise ValueError()
        fd=os.open(path.anchor,flags);opened.append(fd)
        for part in path.parts[1:]:
            fd=os.open(part,flags,dir_fd=fd);opened.append(fd)
        result=opened.pop()
        return result
    finally:
        for fd in opened:
            os.close(fd)

def run_bounded(argv, deadline, max_bytes=MAX_INPUT):
    """One private bounded pipe, discarded stderr, bounded group termination."""
    remaining=deadline-time.monotonic()
    if remaining<=0:
        return 'timed-out',None
    try:
        process=subprocess.Popen(argv,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
                                 start_new_session=os.name=='posix')
    except (OSError,ValueError):
        return 'unavailable',None
    data=bytearray();overflow=threading.Event();done=threading.Event()
    def drain():
        try:
            while True:
                chunk=os.read(process.stdout.fileno(),8192)
                if not chunk:
                    break
                space=max_bytes+1-len(data)
                if space>0:
                    data.extend(chunk[:space])
                if len(data)>max_bytes:
                    overflow.set();break
        except (OSError,ValueError):
            pass
        finally:
            done.set()
    reader=threading.Thread(target=drain,daemon=True);reader.start()
    cutoff=min(deadline,time.monotonic()+10)
    reason=None
    while process.poll() is None or not done.is_set():
        if overflow.is_set():
            reason='oversize';break
        if time.monotonic()>=cutoff:
            reason='timed-out';break
        time.sleep(min(.01,max(0,cutoff-time.monotonic())))
    if reason:
        with contextlib.suppress(OSError):
            if os.name=='posix':
                os.killpg(process.pid,signal.SIGKILL)
            else:
                process.kill()
        with contextlib.suppress(subprocess.TimeoutExpired):
            process.wait(timeout=.1)
    reader.join(timeout=.1)
    with contextlib.suppress(OSError):
        process.stdout.close()
    if reason or overflow.is_set():
        return reason or 'oversize',None
    if process.returncode!=0:
        return 'failed',None
    return 'available',bytes(data)

def parse_crash(raw, device, start, end, runner):
    """Modern two-object IPS or translated crash; output only fixed fields."""
    if len(raw)>MAX_INPUT:
        return 'oversize',None
    try:
        body=raw.decode('utf-8',errors='strict')
        if body.lstrip().startswith('{'):
            first,rest=body.split('\n',1)
            metadata=_json(first);report=_json(rest)
            if not isinstance(metadata,dict) or not isinstance(report,dict):
                raise ValueError()
            if str(metadata.get('bug_type'))!='309':
                return 'unsupported',None
            if any(report.get(key) in (True,'true') for key in ('isNonFatal','isSimulated')):
                return 'unsupported',None
            bundle=report.get('bundleInfo',{}).get('CFBundleIdentifier')
            if metadata.get('bundleID')!=bundle:
                return 'unassociated',None
            process=report.get('procName');path=report.get('procPath');stamp=_epoch(report.get('captureTime'))
            if metadata.get('name')!=process:
                return 'unassociated',None
            exception=report.get('exception',{});termination=report.get('termination',{})
            fault=report.get('faultingThread');frames=[];all_frames=[]
            threads=report.get('threads',[]);images=report.get('usedImages',[])
            if type(fault) is int and 0<=fault<len(threads) and isinstance(threads[fault],dict):
                all_frames=threads[fault].get('frames',[])
                if not isinstance(all_frames,list):
                    raise ValueError()
                for frame in all_frames[:256]:
                    if not isinstance(frame,dict):
                        continue
                    index=frame.get('imageIndex');symbol=_symbol(frame.get('symbol'))
                    image=images[index].get('name') if type(index) is int and 0<=index<len(images) and isinstance(images[index],dict) else None
                    if image in IMAGES and len(frames)<16:
                        frames.append({'image':image,'symbol':symbol or 'withheld'})
        else:
            def field(name):
                matches=re.findall(r'^'+re.escape(name)+r':\s*(.*)$',body,re.M)
                if len(matches)>1:
                    raise ValueError()
                return matches[0] if matches else None
            process_match=re.fullmatch(r'([A-Za-z0-9-]+) \[\d+\]',field('Process') or '')
            process=process_match[1] if process_match else None
            bundle=field('Identifier');path=field('Path');stamp=_epoch(field('Date/Time'))
            if any(token in (field('Exception Note') or '') for token in ('NON-FATAL','SIMULATED')):
                return 'unsupported',None
            em=re.fullmatch(r'(EXC_[A-Z_]+)(?: \((SIG[A-Z]+)\))?',field('Exception Type') or '')
            exception={'type':em[1],'signal':em[2]} if em else {}
            tm=re.match(r'Namespace ([A-Z]+), Code (0x[0-9A-Fa-f]+|\d+)(?:\s|$)',field('Termination Reason') or '')
            termination={'namespace':tm[1],'code':int(tm[2],0) if tm[2].startswith('0x') else int(tm[2])} if tm else {}
            triggered=field('Triggered by Thread') or field('Crashed Thread') or ''
            fm=re.match(r'^(\d+)(?:\s|$)',triggered);fault=int(fm[1]) if fm else None
            frames=[];all_frames=[]
            if fault is not None:
                match=re.search(r'^Thread '+str(fault)+r' Crashed[^\n]*:\s*\n([^\n]*(?:\n(?!\n|Thread )[0-9][^\n]*)*)',body,re.M)
                if match:
                    all_frames=match[1].splitlines()
                    for line in all_frames[:256]:
                        frame=re.fullmatch(r'\s*\d+\s+(\S+)\s+0x[0-9A-Fa-f]+\s+(.+?)(?: \+ \d+)?\s*',line)
                        if frame:
                            symbol=_symbol(frame[2])
                            if frame[1] in IMAGES and len(frames)<16:
                                frames.append({'image':frame[1],'symbol':symbol or 'withheld'})
        allowed={APP:('app','ApartmentFinder')}
        if runner==RUNNER:
            allowed[RUNNER]=('runner','ApartmentFinderUITests-Runner')
        if bundle not in allowed or process!=allowed[bundle][1]:
            return 'unassociated',None
        uuid=r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}'
        canonical=r'/Users/[A-Za-z0-9_-]+/Library/Developer/CoreSimulator/Devices/'+re.escape(device)+ \
          r'/data/Containers/Bundle/Application/'+uuid+'/'+re.escape(process)+r'\.app/'+re.escape(process)
        if type(path) is not str or not re.fullmatch(canonical,path,re.I):
            return 'unassociated',None
        if stamp is None or not start<=stamp<=end:
            return 'unassociated',None
        if not isinstance(exception,dict) or not isinstance(termination,dict):
            raise ValueError()
        ex={k:exception[k] for k,allow in (('type',EXCEPTIONS),('signal',SIGNALS)) if exception.get(k) in allow}
        term={}
        if termination.get('namespace') in NAMESPACES:
            term['namespace']=termination['namespace']
        code=termination.get('code')
        if type(code) is int and 0<=code<=2**64-1:
            term['code']=code
        result=dict(role=allowed[bundle][0],captureTime=_utc(stamp),exception=ex,termination=term,
                    faultingThread=fault if type(fault) is int and 0<=fault<=4096 else None,
                    frames=frames,framesTruncated=len(all_frames)>16,association='execution-window-and-created-device',
                    pidCorrelation='unavailable')
        return 'accepted',result
    except (ValueError,TypeError,KeyError,IndexError,AttributeError,OverflowError,RecursionError):
        return 'malformed',None

def reduce_tests(tree, selected, start=None, finish=None):
    rows=[];seen=set()
    try:
        for node in _walk(tree):
            if node.get('nodeType') not in ('Test Case','TestCase'):
                continue
            ident=_identity(node.get('nodeIdentifier',node.get('testIdentifier')),selected)
            if ident is None or ident in seen:
                return 'invalid',[]
            seen.add(ident)
            result={'Passed':'passed','Failed':'failed','Skipped':'skipped','Expected Failure':'expected-failure'}.get(node.get('result'),'unavailable')
            row={'id':ident,'result':result,'durationSeconds':_number(node.get('duration'),0,5400)}
            begin=_epoch(node.get('startTime'));end=_epoch(node.get('finishTime',node.get('endTime')))
            window_valid=_epoch(start) is not None and _epoch(finish) is not None and start<=finish
            admitted=window_valid and begin is not None and end is not None and start<=begin<=end<=finish
            row['startTime']=_utc(begin) if admitted else None
            row['endTime']=_utc(end) if admitted else None
            row['timingStatus']='observed' if admitted else 'out-of-window' if window_valid and begin is not None and end is not None else 'unavailable'
            rows.append(row)
        if not rows:
            return 'unavailable',[]
        rows.sort(key=lambda x:selected.index(x['id']))
        return ('complete' if seen==set(selected) else 'incomplete'),rows
    except (ValueError,TypeError,RecursionError):
        return 'invalid',[]

def reduce_activities(tree, start, end):
    rows=[]
    tokens=(('unexpected termination','unexpected-termination'),('predicate','predicate'),
      ('snapshot','accessibility-snapshot'),('tear down','teardown'),('launch','launch'),
      ('drag','drag'),('tap','tap'),('find the','accessibility-lookup'))
    try:
        for node in _walk(tree,('activities','testActivities','children','childActivities')):
            title=node.get('title',node.get('name'))
            if type(title) is not str:
                continue
            kind=next((value for text,value in tokens if text in title[:1024].lower()),None)
            begin=_epoch(node.get('startTime'));finish=_epoch(node.get('finishTime',node.get('endTime')))
            if kind and begin is not None and finish is not None and start<=begin<=finish<=end:
                if len(rows)==128:
                    return 'truncated',rows
                rows.append({'kind':kind,'startTime':_utc(begin),'endTime':_utc(finish),
                             'durationSeconds':round(finish-begin,6)})
        return ('available' if rows else 'unavailable'),rows
    except (ValueError,TypeError,RecursionError):
        return 'invalid',[]

def _load(path):
    status,raw=read_regular(path)
    if status!='available':
        return status,None
    try:
        return 'available',_json(raw.decode('utf-8',errors='strict'))
    except (UnicodeError,ValueError,RecursionError):
        return 'malformed',None

def _failures(tree, selected):
    rows=[]
    try:
        for node in _walk(tree):
            if 'testIdentifierString' not in node:
                continue
            ident=_identity(node['testIdentifierString'],selected)
            if ident is None:
                continue
            message=node.get('failureText',node.get('message',''))
            text=message[:4096].lower() if type(message) is str else ''
            category='predicate-timeout' if 'timeout' in text or 'wait failed' in text else 'assertion'
            if 'map' in text and 'value' in text:
                category='map-value-timeout'
            if 'paused' in text:
                category='paused-value-timeout'
            leaf=ident.split('/')[1]+'.swift'
            location=node.get('fileName',node.get('file',''))
            valid_location=type(location) is str and location.replace('\\','/').rsplit('/',1)[-1]==leaf
            line=_number(node.get('lineNumber'),1,100000) if valid_location else None
            rows.append({'id':ident,'category':category,'file':leaf if valid_location else None,
                         'line':int(line) if line is not None else None})
            if len(rows)>=2:
                break
    except (ValueError,TypeError,RecursionError):
        return []
    return rows

def _details(temp, failed, start, end, deadline, command):
    output=[];activity_count=0
    if not failed:
        return output
    result=temp/'synthetic.xcresult'
    try:
        if os.name=='posix':
            descriptor=_directory(result);os.close(descriptor)
        else:
            if not result.is_dir() or any(x.is_symlink() for x in (result,*result.parents)):
                raise ValueError()
    except (OSError,ValueError):
        return [{'id':item,'detailsStatus':'missing','activitiesStatus':'missing','activities':[]} for item in failed]
    support={}
    for subcommand in ('test-details','activities'):
        status,raw=command(['xcrun','xcresulttool','help','get','test-results',subcommand],deadline,16384)
        support[subcommand]=status=='available' and isinstance(raw,bytes) and b'--path' in raw and b'--test-id' in raw
    for ident in failed[:2]:
        row={'id':ident,'activities':[]}
        for subcommand in ('test-details','activities'):
            key='detailsStatus' if subcommand=='test-details' else 'activitiesStatus'
            if not support.get(subcommand):
                row[key]='unsupported';continue
            status,raw=command(['xcrun','xcresulttool','get','test-results',subcommand,
                                '--path',str(result),'--test-id',ident],deadline,MAX_INPUT)
            row[key]=status
            if status!='available':
                continue
            try:
                data=_json(raw.decode('utf-8',errors='strict'))
                if subcommand=='test-details':
                    row['failures']=_failures(data,[ident])
                else:
                    activity_status,activities=reduce_activities(data,start,end)
                    row[key]=activity_status
                    remaining=128-activity_count
                    row['activities']=activities[:remaining]
                    if len(activities)>remaining:
                        row[key]='truncated'
                    activity_count+=len(row['activities'])
            except (ValueError,UnicodeError,RecursionError):
                row[key]='malformed'
        output.append(row)
    return output

def _runner(temp):
    status,raw=read_regular(temp/'DerivedData/Build/Products/Debug-iphonesimulator/ApartmentFinderUITests-Runner.app/Info.plist',65536)
    if status!='available':
        return None
    try:
        value=plistlib.loads(raw)
        return RUNNER if value.get('CFBundleIdentifier')==RUNNER and value.get('CFBundleExecutable')=='ApartmentFinderUITests-Runner' else None
    except (ValueError,TypeError,AttributeError,plistlib.InvalidFileException):
        return None

def _crashes(temp, device, start, end, deadline, tests):
    if sys.platform!='darwin':
        return 'unsupported-platform',[],{}
    runner=_runner(temp);home=Path.home()
    roots=(home/'Library/Logs/DiagnosticReports',home/f'Library/Developer/CoreSimulator/Devices/{device}/data/Library/Logs/DiagnosticReports')
    statuses={};reports=[];seen=set();opened=0;truncated=False
    name_re=re.compile(r'(?:ApartmentFinder|ApartmentFinderUITests-Runner)[-_][A-Za-z0-9_.-]+\.(?:ips|crash)\Z')
    for root in roots:
        if time.monotonic()>=deadline:
            return 'timed-out',reports,statuses
        try:
            descriptor=_directory(root)
            try:
                with os.scandir(descriptor) as entries:
                    for index,entry in enumerate(entries):
                        if index>=128:
                            truncated=True;break
                        if time.monotonic()>=deadline:
                            return 'timed-out',reports,statuses
                        if not name_re.fullmatch(entry.name):
                            continue
                        if opened>=8:
                            truncated=True;break
                        opened+=1
                        status,raw=read_regular(root/entry.name)
                        if status=='available':
                            status,value=parse_crash(raw,device,start,end,runner)
                            if status=='accepted':
                                stamp=_epoch(value['captureTime'])
                                windows=[row for row in tests if row['id'].startswith('ApartmentFinderUITests/')
                                         and row.get('timingStatus')=='observed'
                                         and _epoch(row.get('startTime')) is not None and _epoch(row.get('endTime')) is not None
                                         and start<=_epoch(row['startTime'])<=_epoch(row['endTime'])<=end]
                                associated=[row['id'] for row in windows if _epoch(row['startTime'])<=stamp<=_epoch(row['endTime'])]
                                value['associatedTestIDs']=associated
                                value['perTestAssociation']='observed' if associated else 'unavailable'
                                key=json.dumps(value,sort_keys=True)
                                if key not in seen and len(reports)<2:
                                    reports.append(value);seen.add(key)
                        statuses[status]=statuses.get(status,0)+1
                        if len(reports)==2:
                            truncated=True;break
            finally:
                os.close(descriptor)
        except FileNotFoundError:
            statuses['directory-missing']=statuses.get('directory-missing',0)+1
        except (OSError,ValueError):
            statuses['directory-invalid']=statuses.get('directory-invalid',0)+1
        if len(reports)==2:
            break
    return ('truncated' if truncated else 'available' if reports else 'unavailable'),reports,statuses

def encode_report(report):
    """Valid JSON within the wire bound; never cut UTF-8 or JSON mid-record."""
    report=dict(report);report['outputTruncated']=False
    report['recordType']='public-synthetic-failure-diagnostics'
    # Deliberately disjoint from strict success footers, even after later edits.
    report.pop('scope',None);report.pop('passed',None)
    def encoded():
        return (json.dumps(report,ensure_ascii=True,separators=(',',':'),allow_nan=False)+'\n').encode('utf-8')
    raw=encoded()
    if len(raw)<=MAX_OUTPUT:
        return raw
    report['outputTruncated']=True
    # Reconstructed arrays only. Unknown caller fields cannot force a partial JSON dump.
    for field in ('details','activities','crashes','tests','failures'):
        if field in report:
            report[field]=[]
        raw=encoded()
        if len(raw)<=MAX_OUTPUT:
            return raw
    return b'{"schemaVersion":1,"recordType":"public-synthetic-failure-diagnostics","collectionStatus":"output-bound","outputTruncated":true,"fullAcceptance":false,"releaseEligible":false}\n'

class _Parser(argparse.ArgumentParser):
    def error(self, _message):
        raise ValueError()
    def exit(self, status=0, message=None):
        raise ValueError()

def collect(args, deadline, command=run_bounded):
    temp=Path(args.temp_root)
    report={'schemaVersion':1,'profile':'community-area-controls-regression','sourceCommit':args.source_commit,
      'xcodebuildStatus':args.xcode_status,'resultStatus':args.result_status,
      'fullAcceptance':False,'releaseEligible':False,'collectionStatus':'complete',
      'executionWindow':{'startTime':_utc(args.start_epoch),'endTime':_utc(args.end_epoch)},
      'tests':[],'details':[],'crashes':[]}
    status,selection=_load(temp/'selected-tests.json')
    valid=type(selection) is dict and set(selection)=={'native','ui'} and selection.get('native')==list(EXPECTED[:2]) and \
       type(selection.get('ui')) is list and len(selection['ui'])==4 and set(selection['ui'])==set(EXPECTED[2:])
    if status!='available' or not valid:
        report.update(collectionStatus='selection-invalid',testsStatus=status if status!='available' else 'invalid')
        return report
    status,tree=_load(temp/'tests.json')
    report['testsStatus']=status
    if status=='available':
        report['testsStatus'],report['tests']=reduce_tests(tree,list(EXPECTED),args.start_epoch,args.end_epoch)
    status,summary=_load(temp/'summary.json')
    report['summaryStatus']=status
    report['failures']=_failures(summary,list(EXPECTED)) if status=='available' else []
    failed=[row['id'] for row in report['tests'] if row['result']=='failed']
    # Preserve the most useful termination evidence before optional CLI queries.
    if time.monotonic()<deadline:
        report['crashesStatus'],report['crashes'],report['crashCandidateStatuses']=_crashes(temp,args.device,
          args.start_epoch,args.end_epoch,deadline,report['tests'])
    else:
        report['crashesStatus']='timed-out';report['collectionStatus']='timed-out'
    if len(failed)>2:
        report.update(collectionStatus='failure-count-bound',detailsStatus='unavailable')
    elif time.monotonic()<deadline:
        report['details']=_details(temp,failed,args.start_epoch,args.end_epoch,deadline,command)
    if time.monotonic()>=deadline:
        report['collectionStatus']='timed-out'
    report['timingStatus']='available' if report['tests'] and all(x['startTime'] and x['endTime'] for x in report['tests']) else 'unavailable'
    return report

def main(argv=None):
    # Total work may never restart a fresh minute after the carried job cutoff.
    invocation_start=time.monotonic()
    try:
        parser=_Parser(add_help=False)
        for name in ('temp-root','device','source-commit'):
            parser.add_argument('--'+name,required=True)
        parser.add_argument('--xcode-status',required=True,type=int)
        parser.add_argument('--result-status',required=True,type=int)
        parser.add_argument('--start-epoch',required=True,type=float)
        parser.add_argument('--end-epoch',required=True,type=float)
        parser.add_argument('--deadline-epoch',required=True,type=float)
        args=parser.parse_args(argv)
        if not Path(args.temp_root).is_absolute() or '..' in Path(args.temp_root).parts or not DEVICE_RE.fullmatch(args.device) \
          or not re.fullmatch(r'[0-9a-f]{40}',args.source_commit) or not 0<=args.xcode_status<=255 \
          or not 0<=args.result_status<=255 or _epoch(args.start_epoch) is None or _epoch(args.end_epoch) is None \
          or not args.start_epoch<=args.end_epoch<=args.start_epoch+5400 or _epoch(args.deadline_epoch) is None:
            raise ValueError()
    except (ValueError,TypeError,OverflowError):
        print(encode_report({'schemaVersion':1,'collectionStatus':'invalid-arguments','fullAcceptance':False,'releaseEligible':False}).decode(),end='')
        return 0
    remaining=args.deadline_epoch-time.time()-.5
    deadline=min(invocation_start+59.5,time.monotonic()+max(0,remaining))
    if remaining<=0 or time.monotonic()>=deadline:
        raw=encode_report({'schemaVersion':1,'collectionStatus':'timed-out','xcodebuildStatus':args.xcode_status,
                           'fullAcceptance':False,'releaseEligible':False})
        sys.stdout.write(raw.decode('utf-8'))
        return 0
    try:
        report=collect(args,deadline)
        raw=encode_report(report)
    except Exception:
        raw=encode_report({'schemaVersion':1,'collectionStatus':'unavailable','xcodebuildStatus':args.xcode_status,
                           'fullAcceptance':False,'releaseEligible':False})
    try:
        sys.stdout.write(raw.decode('utf-8'));sys.stdout.flush()
    except (OSError,UnicodeError):
        pass
    return 0

if __name__=='__main__':
    raise SystemExit(main())
