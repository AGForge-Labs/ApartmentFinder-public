#!/usr/bin/env python3
"""Manual local/focused/full validation. Planning is read-only; no CI/signing/upload API exists."""
import argparse
from contextlib import AbstractContextManager
from datetime import datetime,timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import time
import uuid

ROOT=Path(__file__).resolve().parents[1]
PROFILE_PATH='scripts/iteration-profile.json'
# Narrowing requires a reviewed dependency here as well as the editable profile.
# A profile addition alone must never override the conservative fallback.
REVIEWED_CORE={}
REVIEWED_NATIVE={'App/DeliveryMapStyle.swift':['ApartmentFinderUITests/MapAppearanceTests']}

def require(condition,message):
    if not condition:raise ValueError(message)

def digest(value):return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':')).encode()).hexdigest()

def sha(path):
    result=hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):result.update(chunk)
    return result.hexdigest()

def relative(name):
    require(isinstance(name,str) and name and not name.startswith(('/','\\')) and
      '\\' not in name and ':' not in name and '..' not in name.split('/'),'Unsafe repository-relative path')
    return name

def git(root,*args):
    binary=shutil.which('git') or (r'C:\Program Files\Git\cmd\git.exe' if os.name=='nt' else 'git')
    result=subprocess.run([binary,'--no-optional-locks','-c','safe.directory='+Path(root).as_posix(),*args],
      cwd=root,env={**os.environ,'GIT_OPTIONAL_LOCKS':'0','GIT_TERMINAL_PROMPT':'0','GCM_INTERACTIVE':'Never'},
      capture_output=True,timeout=30)
    require(result.returncode==0,'Git read failed: '+result.stderr.decode(errors='replace').strip())
    return result.stdout

def parse_diff(raw,origin):
    parts=raw.decode('utf8',errors='surrogateescape').split('\0');rows=[];at=0
    while at<len(parts) and parts[at]:
        status=parts[at];at+=1
        require(re.fullmatch(r'[ACDMRTUXB][0-9]*',status) is not None and not status.startswith('U'),
          'Unmerged or unknown Git status requires resolution before validation')
        count=2 if status.startswith(('R','C')) else 1
        require(at+count<=len(parts) and all(parts[at:at+count]),'Incomplete Git name/status response')
        rows.append({'status':status,'paths':[relative(p) for p in parts[at:at+count]],'origin':origin});at+=count
    return rows

def collect_changes(root,base):
    rows=[];resolved=None
    if base is not None:
        require(base and not base.startswith('-'),'Explicit base must identify a commit')
        resolved=git(root,'rev-parse','--verify','--end-of-options',base+'^{commit}').decode().strip()
        rows+=parse_diff(git(root,'diff','--name-status','-z','--find-renames',resolved,'HEAD','--'),'base')
    rows+=parse_diff(git(root,'diff','--cached','--name-status','-z','--find-renames','HEAD','--'),'index')
    rows+=parse_diff(git(root,'diff','--name-status','-z','--find-renames','--'),'worktree')
    for name in git(root,'ls-files','--others','--exclude-standard','-z').decode('utf8',errors='surrogateescape').split('\0'):
        if name:rows.append({'status':'A','paths':[relative(name)],'origin':'untracked'})
    return rows,resolved

def source_snapshot(root):
    names=set(git(root,'ls-files','-z').decode('utf8',errors='surrogateescape').split('\0'))
    names.update(git(root,'ls-files','--others','--exclude-standard','-z').decode('utf8',errors='surrogateescape').split('\0'))
    values={}
    for name in sorted(names-{''}):
        path=Path(root)/relative(name)
        if path.is_symlink():values[name]={'link':os.readlink(path)}
        elif path.is_file():values[name]={'sha256':sha(path),'mode':stat.S_IMODE(path.stat().st_mode)}
        elif not path.exists():values[name]={'deleted':True}
        else:raise ValueError('Unsupported source entry: '+name)
    index=hashlib.sha256(git(root,'ls-files','--stage','-z')).hexdigest()
    value={'head':git(root,'rev-parse','HEAD').decode().strip(),'index_sha256':index,'files':values}
    return {**value,'sha256':digest(value)}

def load_profile(root):
    path=Path(root)/PROFILE_PATH
    require(path.is_file() and not path.is_symlink() and path.stat().st_size<64*1024,'Missing bounded iteration profile')
    value=json.loads(path.read_text(encoding='utf8'))
    require(value.get('schema_version')==1,'Unsupported iteration profile')
    for key in ('project','spec','xcode_lock'):relative(value[key])
    require(re.fullmatch(r'[A-Za-z0-9_-]+',value['scheme']) is not None,'Invalid scheme')
    for section in ('core_focus','native_focus'):
        require(isinstance(value[section],dict),'Invalid focus map')
        for path,names in value[section].items():
            relative(path);require(isinstance(names,list) and names and len(set(names))==len(names),'Invalid focus mapping')
            pattern=r'[A-Za-z0-9_]+' if section=='core_focus' else r'[A-Za-z0-9_]+/[A-Za-z0-9_]+'
            require(all(isinstance(name,str) and re.fullmatch(pattern,name) for name in names),'Invalid test identity')
    require(all(type(value['full_acceptance'][key]) is int and value['full_acceptance'][key]>0
      for key in ('native','ui','original_pngs')),'Full gate inventory must remain explicit')
    return value

def plain_doc(root,name,base=None):
    if not (name=='README.md' or (name.startswith('docs/') and name.endswith('.md'))):return False
    path=Path(root)/name
    if path.is_symlink():return False
    try:
        indexed=git(root,'ls-files','--stage','--',name).decode()
        if indexed and indexed.split(' ',1)[0]!='100644':return False
        # Deleted/staged-renamed Markdown can lose its index mode. Check originals too.
        for ref in dict.fromkeys(['HEAD',*([base] if base else [])]):
            original=git(root,'ls-tree','-z',ref,'--',name).decode('utf8')
            if original and original.split(' ',1)[0]!='100644':return False
        if path.exists():
            if not path.is_file() or path.stat().st_size>1024*1024 or path.stat().st_mode & 0o111:return False
            body=path.read_text(encoding='utf8')
        else:body=git(root,'show','HEAD:'+name).decode('utf8')
        return not body.lstrip().startswith('#!') and re.search(r'<\s*script\b',body,re.I) is None
    except (ValueError,OSError,UnicodeError):return False

def test_ids(root,folder):
    result=[]
    for path in sorted((Path(root)/folder).glob('*.swift')):
        text=path.read_text(encoding='utf8');classes=list(re.finditer(r'\bclass\s+(\w+)\s*:\s*XCTestCase\b',text))
        for at,match in enumerate(classes):
            end=classes[at+1].start() if at+1<len(classes) else len(text)
            result += [match[1]+'/'+name for name in re.findall(r'\bfunc\s+(test\w+)\s*\(',text[match.end():end])]
    require(len(result)==len(set(result)),'Duplicate or ambiguous XCTest identities: '+folder)
    return sorted(result)

def validate_mappings(root,profile):
    core=test_ids(root,'Tests/ApartmentCoreTests')
    for classes in profile['core_focus'].values():
        for cls in classes:require(any(i.startswith(cls+'/') for i in core),'Mapped core class is absent: '+cls)
    for classes in profile['native_focus'].values():
        for item in classes:
            target,cls=item.split('/')
            require(target in ('ApartmentFinderTests','ApartmentFinderUITests'),'Unknown mapped native target: '+target)
            folder='NativeTests' if target=='ApartmentFinderTests' else 'UITests'
            require(any(i.startswith(cls+'/') for i in test_ids(root,folder)),'Mapped native class is absent: '+item)

def reviewed_focus(profile,name):
    return name in set(REVIEWED_CORE)|set(REVIEWED_NATIVE) and all(
      sorted(profile[section].get(name,[]))==sorted(mapping.get(name,[]))
      for section,mapping in (('core_focus',REVIEWED_CORE),('native_focus',REVIEWED_NATIVE)))

def classify(root,changes,profile,base=None):
    suites=set();filters=set();native=set();full=False;docs_only=True;reasons=[];syntax=False
    for row in changes:
        for name in row['paths']:
            if plain_doc(root,name,base):continue
            docs_only=False
            destructive=row['status'].startswith(('R','D','T','C'))
            if name in ('scripts/iterate.py',PROFILE_PATH,'Config/Iteration-Package.resolved') or name.startswith('Tests/iteration/'):
                suites.add('iteration');full=True;reasons.append('validation infrastructure: '+name);continue
            if reviewed_focus(profile,name) and name in profile['native_focus'] and not name.startswith('Sources/') and not destructive:
                native.update(profile['native_focus'][name]);syntax=True;continue
            if name.startswith(('NativeTests/','UITests/')) and name.endswith('.swift') and not destructive:
                folder=name.split('/')[0];ids=test_ids(root,folder)
                text=(Path(root)/name).read_text(encoding='utf8') if (Path(root)/name).is_file() else ''
                classes=re.findall(r'\bclass\s+(\w+)\s*:\s*XCTestCase\b',text)
                if len(classes)==1 and any(i.startswith(classes[0]+'/') for i in ids):
                    target='ApartmentFinderTests' if folder=='NativeTests' else 'ApartmentFinderUITests'
                    native.add(target+'/'+classes[0]);syntax=True;continue
            full=True;reasons.append('full native gate required: '+name)
            if name.startswith(('Sources/ApartmentCore/','Tests/ApartmentCoreTests/')):suites.add('core');filters.add('*')
            elif name.startswith(('data/','scripts/data/','Tests/data/','research/')):suites.update(('core','node'));filters.add('*')
            elif name.startswith('services/geocoding/'):suites.add('proxy')
            elif name.startswith(('Tests/signing/','scripts/testflight','scripts/validate-checkout')):suites.add('signing')
            elif name.startswith(('App/','SharedUI/','ShareExtension/','NativeTests/','UITests/')):
                suites.add('core');filters.add('*');syntax=True
            else:suites.update(('core','node','signing','iteration'));filters.add('*');syntax=True
    if 'node' in suites:suites.discard('proxy')
    return {'docs_only':docs_only,'local_suites':sorted(suites),'core_filters':[] if '*' in filters else sorted(filters),
      'native_tests':sorted(native),'full_native_required':full,'syntax':syntax,'reasons':sorted(set(reasons))}

def swift_prefix(root,profile,binary,system):
    if system!='Windows':return [binary]
    drive=Path(root).drive.rstrip(':').lower();require(re.fullmatch('[a-z]',drive) is not None,'WSL needs a Windows drive path')
    executable=profile['wsl_swift'] if binary=='swift' else str(Path(profile['wsl_swift']).with_name('swiftc')).replace('\\','/')
    tool_path=str(Path(profile['wsl_swift']).parent).replace('\\','/')+':/usr/bin:/bin'
    prefix=['wsl.exe','-d',profile['wsl_distribution'],'--exec','/usr/bin/env','PATH='+tool_path,
      '/usr/bin/timeout','--signal=TERM','--kill-after=5s','900s',
      '/usr/bin/taskset','-c','0','/usr/bin/nice','-n','10',executable]
    return prefix

def make_plan(root,mode='local',base=None,core_filter=None,destination=None,runtime=None,portable_only=False,fresh=False):
    root=Path(root).resolve();require(mode in ('local','native','release'),'Unknown mode')
    before=source_snapshot(root)
    base_before=git(root,'rev-parse','--verify','--end-of-options',base+'^{commit}').decode().strip() if base else None
    profile=load_profile(root);changes,resolved=collect_changes(root,base)
    require(resolved==base_before,'Base changed during planning')
    require(changes,'No changed paths: provide an explicit --base commit/ref for committed work')
    require(core_filter is None or mode=='local','A manual test filter cannot produce a full/native release run')
    require(not portable_only or (mode=='local' and core_filter is None),'Portable-only is a local check without a Core filter')
    validate_mappings(root,profile)
    selection=classify(root,changes,profile,resolved);commands=[];system=platform.system();deferred=[]
    if portable_only:
        if 'core' in selection['local_suites']:deferred.append('core: requires the configured Swift toolchain and pinned dependency')
        if selection['syntax']:deferred.append('syntax: requires the configured Swift compiler')
        selection['local_suites']=sorted((set(selection['local_suites'])-{'core','proxy'})|{'node','signing','iteration'})
    selection['selected_core_ids']=[];selection['selected_native_ids']=[]
    def add(kind,args):commands.append({'kind':kind,'argv':[str(x) for x in args]})
    if core_filter is not None:
        require(core_filter and len(core_filter)<=512,'A bounded nonempty core filter is required')
        expression=re.compile(core_filter)
        require(any(expression.search(i) for i in test_ids(root,'Tests/ApartmentCoreTests')),'Core filter matches no existing test')
        selection['local_suites']=sorted(set(selection['local_suites'])|{'core'})
    if mode=='local':
        for suite in selection['local_suites']:
            if suite=='core':
                package_path='/mnt/'+root.drive[0].lower()+root.as_posix()[2:] if system=='Windows' else str(root)
                args=swift_prefix(root,profile,'swift',system)+['test','--package-path',package_path,'--jobs','1','--disable-automatic-resolution','--skip-update']
                chosen=core_filter or '|'.join(selection['core_filters'])
                selection['selected_core_ids']=[i for i in test_ids(root,'Tests/ApartmentCoreTests') if not chosen or re.search(chosen,i)]
                require(selection['selected_core_ids'],'Selected core tests are absent')
                if chosen:
                    args+=['--filter',chosen]
                add('core',args)
            elif suite in ('node','proxy'):
                paths=sorted((root/'Tests/data').glob('*.test.mjs')) if suite=='node' else []
                proxy=root/'services/geocoding/worker.test.mjs';require(proxy.is_file(),'Selected proxy test file is absent')
                if suite=='node':require(paths,'Selected Node data tests are absent')
                add('node',['node','--test','--test-concurrency=1',*map(str,paths),str(proxy)])
            elif suite in ('signing','iteration'):
                folder=root/'Tests'/suite;require(list(folder.glob('test_*.py')),'Selected Python tests are absent: '+str(folder))
                add('python',[sys.executable,'-B','-m','unittest','discover','-s',str(folder),'-v'])
        if selection['syntax'] and not portable_only:
            files=[p for folder in ('App','SharedUI','NativeTests','UITests','ShareExtension') for p in sorted((root/folder).glob('*.swift'))]
            require(files,'No Swift app sources to parse')
            if system=='Windows':
                files=['/mnt/'+p.drive[0].lower()+p.as_posix()[2:] for p in files]
            add('syntax',swift_prefix(root,profile,'swiftc',system)+['-frontend','-parse','-D','DEBUG',*map(str,files)])
    elif mode=='release':
        require(runtime,'Release planning needs an explicit installed --runtime identifier')
        add('full-native',['bash',str(root/'scripts/validate-ios.sh'),runtime,'com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro'])
    elif not selection['docs_only'] and not selection['full_native_required']:
        require(destination,'Focused native planning needs an explicit Simulator --destination UUID')
        require(selection['native_tests'],'No defensible native mapping; use the full release checkpoint')
        for item in selection['native_tests']:
            target,cls=item.split('/');folder='NativeTests' if target=='ApartmentFinderTests' else 'UITests'
            ids=[target+'/'+i for i in test_ids(root,folder) if i.startswith(cls+'/')]
            require(ids,'Selected native class is absent: '+item)
            selection['selected_native_ids']+=ids
        cache=root/'build/iteration/native-cache/<compatibility-key>/DerivedData'
        common=['xcodebuild','-project',str(root/profile['project']),'-scheme',profile['scheme'],'-configuration','Debug',
          '-sdk','iphonesimulator','-destination','id='+destination,'-derivedDataPath',str(cache),'-jobs','1',
          '-parallel-testing-enabled','NO','-disableAutomaticPackageResolution','-onlyUsePackageVersionsFromResolvedFile',
          'CODE_SIGNING_ALLOWED=YES','CODE_SIGN_IDENTITY=-','CODE_SIGNING_REQUIRED=NO']
        add('generate',['xcodegen','generate','--spec',str(root/profile['spec'])])
        add('build',common+['build-for-testing'])
        add('focused-native',['xcodebuild','test-without-building','-xctestrun',str(cache/'Build/Products/<verified>.xctestrun'),
          '-destination','id='+destination,'-parallel-testing-enabled','NO',*['-only-testing:'+item for item in selection['native_tests']]])
    after=source_snapshot(root)
    base_after=git(root,'rev-parse','--verify','--end-of-options',base+'^{commit}').decode().strip() if base else None
    require(before==after and resolved==base_after,'Source or base changed during planning; regenerate the plan')
    return {'schema_version':1,'mode':mode,'scope':'custom-local' if core_filter else mode+'-iteration',
      'root':str(root),'base_requested':base,'base_resolved':resolved,'changes':changes,'selection':selection,
      'source':before,'profile':profile,'commands':commands,'destination':destination,'runtime':runtime,
      'portable_only':portable_only,'deferred_checks':deferred,'fresh':fresh,
      'full_acceptance':False,'release_eligible':False,'full_gate_inventory':profile['full_acceptance'],
      'limitations':['Iteration receipts never satisfy frozen release acceptance.','Focused checks do not clear the outstanding full native/screenshot gate.',
        'No CI dispatch, distribution signing, upload, budget action or simulator erasure is performed.']}

def native_environment():
    require(not os.environ.get('XCODE_XCCONFIG_FILE'),'External Xcode configuration override is not supported; unset XCODE_XCCONFIG_FILE')
    keys=('PATH','HOME','TMPDIR','TMP','TEMP','USER','LOGNAME','SHELL','LANG','LC_ALL','LC_CTYPE','DEVELOPER_DIR','TERM')
    return {**{key:os.environ[key] for key in keys if key in os.environ},
      'PYTHONDONTWRITEBYTECODE':'1','HOMEBREW_NO_AUTO_UPDATE':'1'}

def fingerprint(root,profile,tools,source,environment=None):
    effective=native_environment() if environment is None else environment
    require(not any('link' in value for value in source['files'].values()),'Native source symlinks require explicit reconciliation')
    dependencies={name:value for name,value in source['files'].items() if name in
      ('Package.swift','Package.resolved',PROFILE_PATH,profile['spec'],profile['xcode_lock']) or name.startswith('Config/')}
    # Launch/output identities are evidence, not binary inputs. Actual tool/image/config values remain bound.
    behavior={key:effective[key] for key in ('DEVELOPER_DIR','LANG','LC_ALL','LC_CTYPE') if key in effective}
    compatibility={'tools':{key:val for key,val in tools.items() if key!='destination'},'dependencies':dependencies,'profile':profile,
      'sdk':'iphonesimulator','configuration':'Debug','scheme':profile['scheme'],'targets':['app','native tests','UI tests'],'environment':behavior}
    return {'compatibility_sha256':digest(compatibility),'source_sha256':source['sha256'],
      'platforms_directory':tools.get('platforms_directory'),'sha256':digest({'compatibility':compatibility,'source':source['sha256']})}

def tree_hashes(path,allowed):
    path=Path(path);allowed=Path(allowed).resolve();values={}
    def visit(current,name,ancestors):
        resolved=current.resolve();require(resolved.is_relative_to(allowed),'Build product link escapes the owned cache')
        if current.is_dir():
            require(resolved not in ancestors,'Build product link cycle')
            for child in sorted(current.iterdir()):visit(child,name+'/'+child.name,ancestors|{resolved})
        else:
            require(current.is_file(),'Missing or unsupported build product')
            values[name]={'sha256':sha(current),'mode':stat.S_IMODE(current.stat().st_mode)}
    require(path.is_dir(),'Build products are absent')
    visit(path,'',set());require(values,'Empty product directory')
    return values

def generated_inputs(root,profile):
    return tree_hashes(Path(root)/profile['project'],root)

def xctestrun_references(path,products,platforms=None):
    """Validate v1/v2 test descriptions at their original paths; relocation is not inferred."""
    products=Path(products).resolve();references={};bundles=[]
    platforms=Path(platforms).resolve() if platforms else None
    def resolve(value,host=None):
        require(isinstance(value,str) and value,'Missing product reference')
        value=value.replace('__TESTROOT__',str(products))
        if host is not None:value=value.replace('__TESTHOST__',str(host))
        if platforms is not None:value=value.replace('__PLATFORMS__',str(platforms))
        require('__' not in value,'Unresolved product reference: '+value)
        result=Path(value)
        require(result.is_absolute(),'Relative product reference without TESTROOT')
        require(result.exists(),'Missing product reference: '+value);resolved=result.resolve()
        external=platforms is not None and resolved.is_relative_to(platforms)
        require(resolved.is_relative_to(products) or external,'External product reference outside the bound Xcode platforms: '+value)
        references[str(resolved)]=tree_hashes(result,platforms) if external and result.is_dir() else \
          {'sha256':sha(result),'mode':stat.S_IMODE(result.stat().st_mode)} if external else 'products'
        return result
    def visit(node):
        if isinstance(node,dict):
            if 'TestBundlePath' in node:
                host=resolve(node['TestHostPath']) if 'TestHostPath' in node else None
                bundle=resolve(node['TestBundlePath'],host)
                require(bundle.is_dir() and bundle.suffix=='.xctest' and any(bundle.iterdir()),'Missing test bundle contents')
                bundles.append(str(bundle.resolve()))
                if 'UITargetAppPath' in node:resolve(node['UITargetAppPath'],host)
                for item in node.get('DependentProductPaths',[]):resolve(item,host)
            for value in node.values():visit(value)
        elif isinstance(node,list):
            for value in node:visit(value)
    with Path(path).open('rb') as stream:visit(plistlib.load(stream))
    require(bundles,'No referenced test bundles in xctestrun')
    return references

def save_cache(root,profile,cache,value):
    cache=Path(cache);products=cache/'DerivedData/Build/Products'
    runs=list(products.glob('*.xctestrun'));require(len(runs)==1,'Expected one verified xctestrun product')
    record={'schema_version':1,'fingerprint':value,'products':tree_hashes(products,cache),
      'references':xctestrun_references(runs[0],products,value.get('platforms_directory')),
      'generated':generated_inputs(root,profile),'xctestrun':runs[0].name}
    temporary=cache/('ready-'+uuid.uuid4().hex+'.tmp');temporary.write_text(json.dumps(record,sort_keys=True),encoding='utf8')
    os.replace(temporary,cache/'ready.json')

def reusable(root,profile,cache,value):
    try:
        path=Path(cache)/'ready.json'
        if path.is_symlink() or not path.is_file() or path.stat().st_size>16*1024*1024:return False
        record=json.loads(path.read_text(encoding='utf8'))
        products=Path(cache)/'DerivedData/Build/Products'
        return record.get('schema_version')==1 and record.get('fingerprint')==value and \
          record.get('products')==tree_hashes(products,cache) and record.get('generated')==generated_inputs(root,profile) and \
          len(list(products.glob('*.xctestrun')))==1 and record['xctestrun']==next(products.glob('*.xctestrun')).name and \
          record.get('references')==xctestrun_references(products/record['xctestrun'],products,value.get('platforms_directory'))
    except (OSError,ValueError,KeyError,StopIteration,plistlib.InvalidFileException):return False

def local_binding(root,command,source):
    """Conservative content binding; only Node's known-independent UI tests are excluded."""
    kind=command['kind'];argv=command['argv'];root=Path(root)
    require(kind in ('core','node','python','syntax'),'Unsupported local check')
    if any(os.environ.get(key) for key in ('NODE_OPTIONS','NODE_PATH','PYTHONPATH','PYTHONHOME','SWIFT_EXEC','SDKROOT','XCODE_XCCONFIG_FILE')):return None
    binary=shutil.which(argv[0]);require(binary is not None,'Missing local tool: '+argv[0])
    version_command=argv[:argv.index('test')] if kind=='core' else argv[:argv.index('-frontend')] if kind=='syntax' else [binary]
    version=subprocess.check_output([*version_command,'--version'],cwd=root,stderr=subprocess.STDOUT,timeout=30).decode(errors='replace').strip()
    files={name:value for name,value in source['files'].items()
      if kind!='node' or not name.startswith(('UITests/','NativeTests/'))}
    dependencies={}
    if kind=='core' and (root/'.build/checkouts').is_dir():dependencies=tree_hashes(root/'.build/checkouts',root/'.build')
    return digest({'command':command,'files':files,'dependencies':dependencies,'binary':str(Path(binary).resolve()),
      'binary_sha256':sha(binary),'version':version,'platform':platform.platform(),'environment_sha256':digest(dict(os.environ))})

def cached_local(root,command,binding):
    try:
        record=json.loads(owned_output(root,'local-passes',binding+'.json').read_text())
        proof=Path(record['receipt']);require(proof.resolve().is_relative_to(owned_output(root,'runs').resolve()),'External local proof')
        require(sha(proof)==record['receipt_sha256'],'Changed original local receipt')
        receipt=json.loads(proof.read_text());age=(datetime.now(timezone.utc)-datetime.fromisoformat(receipt['completed_at_utc'])).total_seconds()
        require(receipt['status']=='passed-scoped-checks' and receipt['mode']=='local' and 0<=age<=86400,'Not a fresh complete local pass')
        matches=[item for item in receipt['commands'] if item.get('input_sha256')==binding and not item.get('reused')]
        require(len(matches)==1,'Ambiguous original local pass');original=matches[0];log=Path(original['log'])
        require(original['argv']==command['argv'] and original['kind']==command['kind'] and original['exit_code']==0,'Different local check')
        require(log.resolve().is_relative_to(proof.parent.resolve()) and sha(log)==original['log_sha256'],'Changed original local log')
        if command['kind'] in ('core','node','python'):require(test_counts(command['kind'],log.read_text(encoding='utf8'))==original['counts'],'Changed test counts')
        return {**original,'reused':True,'original_receipt':str(proof),'elapsed_seconds':0}
    except (OSError,ValueError,KeyError,TypeError):return None

def save_local_passes(root,receipt):
    if receipt['mode']!='local' or receipt['status']!='passed-scoped-checks':return
    folder=owned_output(root,'local-passes');folder.mkdir(exist_ok=True)
    for command in receipt['commands']:
        if command.get('input_sha256') and not command.get('reused'):
            (folder/(command['input_sha256']+'.json')).write_text(json.dumps({'receipt':receipt['path'],'receipt_sha256':sha(receipt['path'])}),encoding='utf8')

def owned_output(root,*parts):
    root=Path(root).resolve();path=root.joinpath('build','iteration',*parts)
    require(path.resolve().is_relative_to(root),'Iteration output must stay inside this checkout')
    return path

class IterationLock(AbstractContextManager):
    def __init__(self,root,token=None,name='run.lock'):self.path=owned_output(root,relative(name));self.token=token or uuid.uuid4().hex
    def __enter__(self):
        self.path.parent.mkdir(parents=True,exist_ok=True)
        try:
            with self.path.open('x',encoding='utf8') as stream:json.dump({'pid':os.getpid(),'token':self.token},stream)
        except FileExistsError:raise ValueError('An iteration lock already exists. Do not cancel releases or delete another owner\'s lock; reconcile a stale local lock manually.') from None
        return self
    def __exit__(self,*args):
        if self.path.is_file() and json.loads(self.path.read_text())['token']==self.token:self.path.unlink()

def test_counts(kind,body):
    if kind=='core':
        rows=re.findall(r'Executed (\d+) tests?, with (\d+) failures?',body);require(rows,'Missing Swift test counts')
        total=max(int(row[0]) for row in rows);failed=max(int(row[1]) for row in rows)
        require(not re.search(r'Test Case .* skipped|\d+ tests? skipped|expected failure',body,re.I),'Skipped or expected-failure Swift tests')
        result={'passed':total-failed,'failed':failed,'skipped':0,'expected_failures':0}
    elif kind=='node':
        def count(key):
            found=re.findall(r'^# '+key+r' (\d+)\s*$',body,re.M);require(len(found)==1,'Missing or ambiguous TAP count '+key);return int(found[0])
        total=count('tests');passed=count('pass');failed=count('fail');skipped=count('skipped')
        require(count('cancelled')==count('todo')==0 and total==passed+failed+skipped,'Incomplete Node tests')
        result={'passed':passed,'failed':failed,'skipped':skipped,'expected_failures':0}
    elif kind=='python':
        rows=re.findall(r'Ran (\d+) tests? in ',body);require(len(rows)==1 and re.search(r'^OK\s*$',body,re.M),'Missing complete unittest result')
        result={'passed':int(rows[0]),'failed':0,'skipped':0,'expected_failures':0}
    else:
        value=json.loads(body)
        keys=('passedTests','failedTests','skippedTests','expectedFailures','totalTestCount')
        require(all(type(value.get(key)) is int for key in keys),'Unknown xcresult summary schema')
        require(value['totalTestCount']==sum(value[key] for key in ('passedTests','failedTests','skippedTests')),'Inconsistent xcresult counts')
        result=dict(zip(('passed','failed','skipped','expected_failures'),(value[key] for key in keys[:4])))
    require(result['passed']>0 and result['failed']==result['skipped']==result['expected_failures']==0,'Zero, failed, skipped or expected-failure tests cannot pass')
    return result

def exact_ids(observed,expected):
    require(expected and len(observed)==len(expected) and len(set(observed))==len(observed)
      and sorted(observed)==sorted(expected),'Missing, duplicated or substituted selected test identities')
    return sorted(observed)

def verify_core_ids(body,expected):
    def normalize(label):
        match=re.fullmatch(r'-\[[A-Za-z0-9_]+\.([A-Za-z0-9_]+) (test[A-Za-z0-9_]+)\]',label) or \
          re.fullmatch(r'([A-Za-z0-9_]+)\.(test[A-Za-z0-9_]+)(?:\(\))?',label)
        require(match is not None,'Unknown Core test identity syntax')
        return match[1]+'/'+match[2]
    started=[normalize(x) for x in re.findall(r"(?m)^Test Case '([^']+)' started(?:\.| at [^\n]+)$",body)]
    passed=[normalize(x) for x in re.findall(r"(?m)^Test Case '([^']+)' passed \([^\n]+\)\.?$",body)]
    exact_ids(started,expected);return exact_ids(passed,expected)

def verify_native_ids(tree,expected):
    observed=[]
    def visit(node):
        if isinstance(node,dict):
            if node.get('nodeType') in ('Test Case','TestCase'):
                label=node.get('nodeIdentifier',node.get('testIdentifier',''))
                require(isinstance(label,str),'Unknown native test identity')
                parts=label.removesuffix('()').split('/')
                require(len(parts) in (2,3) and re.fullmatch(r'[A-Za-z0-9_]+',parts[-2]) and
                  re.fullmatch(r'test[A-Za-z0-9_]+',parts[-1]) and node.get('result')=='Passed',
                  'Unknown or non-passing native test identity/result')
                matches=[item for item in expected if item==label.removesuffix('()') or
                  (len(parts)==2 and item.endswith('/'+'/'.join(parts)))]
                require(len(matches)==1,'Unknown or ambiguous selected native identity: '+label)
                observed.append(matches[0])
            for value in node.values():visit(value)
        elif isinstance(node,list):
            for value in node:visit(value)
    visit(tree);return exact_ids(observed,expected)

def lower_priority():
    if os.name=='nt':
        import ctypes
        from ctypes import wintypes
        kernel=ctypes.windll.kernel32
        kernel.GetCurrentProcess.restype=wintypes.HANDLE
        kernel.SetPriorityClass.argtypes=[wintypes.HANDLE,wintypes.DWORD]
        kernel.GetProcessAffinityMask.argtypes=[wintypes.HANDLE,ctypes.POINTER(ctypes.c_size_t),ctypes.POINTER(ctypes.c_size_t)]
        kernel.SetProcessAffinityMask.argtypes=[wintypes.HANDLE,ctypes.c_size_t]
        process=kernel.GetCurrentProcess()
        require(kernel.SetPriorityClass(process,0x4000),'Cannot lower this iteration process priority')
        available=ctypes.c_size_t();system=ctypes.c_size_t()
        if kernel.GetProcessAffinityMask(process,ctypes.byref(available),ctypes.byref(system)) and available.value:
            require(kernel.SetProcessAffinityMask(process,ctypes.c_size_t(available.value & -available.value)),
              'Cannot constrain this iteration process to one CPU')
    else:
        try:os.nice(10)
        except OSError:pass
        if hasattr(os,'sched_setaffinity'):os.sched_setaffinity(0,{min(os.sched_getaffinity(0))})

def run_command(argv,cwd,log,timeout,expected,env=None):
    started=time.monotonic();child=None
    record={'argv':argv,'exit_code':None,'log':str(log),'obsolete':False,'aborted':False}
    try:
        with Path(log).open('xb') as stream:
            child=subprocess.Popen(argv,cwd=cwd,stdout=stream,stderr=subprocess.STDOUT,
              env=env if env is not None else {**os.environ,'PYTHONDONTWRITEBYTECODE':'1'},start_new_session=os.name!='nt')
            while child.poll() is None:
                if time.monotonic()-started>timeout:raise TimeoutError('Iteration command exceeded its local timeout')
                # On macOS/Linux stop only this wrapper's own process group when its source becomes obsolete.
                # Windows/WSL is checked between commands; never kill unrelated WSL or release processes.
                if expected is not None and os.name!='nt' and source_snapshot(cwd)['sha256']!=expected:
                    record['obsolete']=True;break
                time.sleep(2)
    except KeyboardInterrupt:
        record.update(aborted=True,error='Interrupted by user')
    except (ValueError,OSError,TimeoutError,subprocess.SubprocessError) as error:
        record['error']=str(error)
    finally:
        if child is not None:
            try:
                if child.poll() is None:
                    if os.name!='nt':os.killpg(child.pid,signal.SIGTERM)
                    else:child.terminate()
                    try:child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        if os.name!='nt':os.killpg(child.pid,signal.SIGKILL)
                        else:child.kill()
                        child.wait(timeout=5)
                record['exit_code']=child.returncode
            except (OSError,subprocess.SubprocessError) as error:record['error']=str(error)
        record['elapsed_seconds']=round(time.monotonic()-started,3)
    return record

def observe_native(root,destination,environment=None):
    require(shutil.which('xcodegen'),'Install/configure XcodeGen separately; this wrapper never installs tools')
    environment=native_environment() if environment is None else environment
    def read(args):return subprocess.check_output(args,cwd=root,env=environment,stderr=subprocess.STDOUT,timeout=25).decode().strip()
    devices=json.loads(read(['xcrun','simctl','list','devices','available','-j']))['devices']
    matching=[(runtime,device) for runtime,items in devices.items() for device in items if device['udid']==destination and device.get('isAvailable')]
    require(len(matching)==1,'Choose an existing available Simulator UUID; no device is created or erased')
    runtimes=json.loads(read(['xcrun','simctl','list','runtimes','-j']))['runtimes']
    runtime=[item for item in runtimes if item['identifier']==matching[0][0] and item.get('isAvailable')]
    require(len(runtime)==1 and runtime[0].get('buildversion') and runtime[0].get('version'),'Unknown Simulator runtime build')
    return {'xcode':read(['xcodebuild','-version']),'sdk':read(['xcrun','--sdk','iphonesimulator','--show-sdk-version']),
      'sdk_build':read(['xcrun','--sdk','iphonesimulator','--show-sdk-build-version']),
      'platforms_directory':str(Path(read(['xcrun','--sdk','iphonesimulator','--show-sdk-platform-path'])).parent),
      'tool_paths':{name:shutil.which(name) for name in ('xcodebuild','xcodegen','swift','xcrun')},
      'swift':read(['swift','--version']),'generator':read(['xcodegen','--version']),
      'developer_dir':environment.get('DEVELOPER_DIR') or read(['xcode-select','-p']),
      'architecture':platform.machine(),'destination':destination,'runtime':matching[0][0],
      'runtime_build':runtime[0]['buildversion'],'runtime_version':runtime[0]['version'],
      'host_os':platform.platform(),'runner_image':{key:os.environ.get(key) for key in ('ImageOS','ImageVersion')},
      'device':matching[0][1].get('deviceTypeIdentifier',matching[0][1]['name'])}

def bound_artifact(out,optional=None,limit=512*1024*1024):
    """Original results win. If they alone exceed the bound, refuse publication."""
    out=Path(out).resolve();removed=False
    def size():return sum(p.stat().st_size for p in out.rglob('*') if p.is_file())
    reserve=min(1024*1024,limit//20)
    if optional is not None:
        optional=Path(optional)
        require(optional.parent.resolve()==out and not optional.is_symlink(),'Optional archive must be owned by this evidence directory')
        if optional.is_file() and size()+reserve>limit:optional.unlink();removed=True
    total=size();within=total+reserve<=limit
    return {'limit_bytes':limit,'bytes':total,'metadata_reserve_bytes':reserve,'retention_days':1,'within_limit':within,
      'publication_allowed':within,'complete':within and not removed,'optional_products_removed':removed}

def preserve_products(cache,out):
    products=Path(cache)/'DerivedData/Build/Products';archive=Path(out)/'build-products.tar'
    # Check link closure before creating an optional archive. Hashes/path bindings remain mandatory on reuse.
    tree_hashes(products,products)
    if sum(p.stat().st_size for p in products.rglob('*') if p.is_file())>512*1024*1024:
        return {'created':False,'reason':'Products alone exceed the unchanged 512 MiB artifact bound'}
    with tarfile.open(archive,'x') as stream:
        stream.add(products,arcname='Build/Products');stream.add(Path(cache)/'ready.json',arcname='ready.json')
    value=bound_artifact(out,archive)
    return {'created':archive.is_file(),'path':str(archive),'relocation_verified':False,'bound':value}

def capture_results(root,out,result,receipt,environment):
    if not result.is_dir():return
    for name,args in (
      ('summary',['get','test-results','summary','--path',str(result)]),
      ('tests',['get','test-results','tests','--path',str(result)]),
      ('attachments',['export','attachments','--path',str(result),'--output-path',str(out/'test-attachments')])):
        log=out/('capture-'+name+'.log')
        try:
            record=run_command(['xcrun','xcresulttool',*args],root,log,60,None,env=environment)
            receipt['commands'].append({**record,'kind':'capture-'+name})
            if record['exit_code']==0 and not record.get('error') and name in ('summary','tests'):
                (out/('test-summary.json' if name=='summary' else 'test-results.json')).write_bytes(log.read_bytes())
        except (OSError,ValueError,KeyboardInterrupt) as error:
            receipt.setdefault('capture_errors',[]).append(str(error) or 'Capture interrupted')

def native_step(root,profile,source,destination,out,receipt,call,selection=None):
    """One build/capture implementation for focused checks and the existing full script."""
    environment=native_environment();expected=source['sha256'];cache=None;value=None
    result=out/('focused.xcresult' if selection is not None else 'native-tests.xcresult')
    with IterationLock(root,name='native.lock'):
        try:
            tools=observe_native(root,destination,environment);receipt['tools']=tools
            # A disposable simulator UUID is not a binary input. Runtime build/device/architecture are.
            build_tools={key:val for key,val in tools.items() if key!='destination'}
            value=fingerprint(root,profile,build_tools,source,environment)
            cache=owned_output(root,'native-cache',value['compatibility_sha256'][:24]);cache.mkdir(parents=True,exist_ok=True)
            require(not cache.is_symlink(),'Cache directory must not be a symlink')
            # Recreate deterministic ignored metadata before comparing a restored build record.
            call(['xcodegen','generate','--spec',str(root/profile['spec'])],'generate')
            lock=root/profile['xcode_lock'];require(lock.is_file(),'Missing pinned Xcode dependency lock')
            target=root/profile['project']/'project.xcworkspace/xcshareddata/swiftpm/Package.resolved';target.parent.mkdir(parents=True,exist_ok=True)
            if target.exists():require(target.read_bytes()==lock.read_bytes(),'Generated dependency lock differs from pinned versions; reconcile explicitly')
            else:target.write_bytes(lock.read_bytes())
            reused=reusable(root,profile,cache,value);receipt.update(native_build_reused=reused,cache_fingerprint=value)
            if not reused:
                marker=cache/'ready.json'
                if marker.exists():marker.unlink()
                dependency_key=digest({'pins':sha(lock),'xcode':tools.get('xcode'),'swift':tools.get('swift'),'architecture':tools.get('architecture')})[:24]
                packages=owned_output(root,'dependency-cache',dependency_key);packages.mkdir(parents=True,exist_ok=True)
                call(['xcodebuild','-project',str(root/profile['project']),'-scheme',profile['scheme'],'-configuration','Debug',
                  '-sdk','iphonesimulator','-destination','id='+destination,'-derivedDataPath',str(cache/'DerivedData'),'-jobs','1',
                  '-clonedSourcePackagesDirPath',str(packages),'-parallel-testing-enabled','NO',
                  '-disableAutomaticPackageResolution','-onlyUsePackageVersionsFromResolvedFile',
                  'CODE_SIGNING_ALLOWED=YES','CODE_SIGN_IDENTITY=-','CODE_SIGNING_REQUIRED=NO','build-for-testing'],'build')
                save_cache(root,profile,cache,value)
            require(reusable(root,profile,cache,value),'Verified build products are incomplete or changed')
            receipt['products_preserved_before_testing']=preserve_products(cache,out)
            metadata=json.loads((cache/'ready.json').read_text());products=cache/'DerivedData/Build/Products'
            filters=[] if selection is None else ['-only-testing:'+item for item in selection['native_tests']]
            call(['xcodebuild','test-without-building','-xctestrun',str(products/metadata['xctestrun']),
              '-destination','id='+destination,'-parallel-testing-enabled','NO','-resultBundlePath',str(result),*filters],
              'focused-native' if selection is not None else 'native-tests')
        finally:
            capture_results(root,out,result,receipt,environment)
            receipt['artifact']=bound_artifact(out,out/'build-products.tar')
            if cache is not None and (cache/'ready.json').exists() and (
              source_snapshot(root)['sha256']!=expected or not reusable(root,profile,cache,value)):(cache/'ready.json').unlink()
        counts=test_counts('native',(out/'test-summary.json').read_text())
        require(source_snapshot(root)==source and reusable(root,profile,cache,value),'Source or build products changed during native testing')
        expected_ids=selection['selected_native_ids'] if selection is not None else [
          target+'/'+item for target,folder in (('ApartmentFinderTests','NativeTests'),('ApartmentFinderUITests','UITests')) for item in test_ids(root,folder)]
        if selection is None:require(len(expected_ids)==profile['full_acceptance']['native']+profile['full_acceptance']['ui'],'Full native inventory differs')
        ids=verify_native_ids(json.loads((out/'test-results.json').read_text()),expected_ids)
        require(len(ids)==counts['passed'],'Different native identity/summary counts')
        require(receipt['artifact']['within_limit'],'Original results exceed the unchanged 512 MiB artifact bound; retained locally, publication refused')
        receipt.update(test_ids=ids,native_counts=counts)

def full_native_step(root,evidence,destination):
    require(platform.system()=='Darwin','Native execution requires macOS/Xcode')
    root=Path(root).resolve();out=Path(evidence).resolve()
    require(out.is_dir() and out.is_relative_to(root/'build'),'Full evidence must be an owned build directory')
    source=source_snapshot(root);receipt={'mode':'full-native','commands':[],'source':source,'full_acceptance':False,'release_eligible':False,'status':'running'}
    def call(argv,kind):
        require(source_snapshot(root)==source,'Source changed before native command')
        log=out/('native-tests.log' if kind=='native-tests' else 'native-'+kind+'.log')
        value=run_command(argv,root,log,2700,source['sha256'],env=native_environment());receipt['commands'].append({**value,'kind':kind})
        require(value['exit_code']==0 and not value.get('error') and not value.get('aborted') and not value.get('obsolete'),'Native command failed: '+kind)
        require(source_snapshot(root)==source,'Source changed during native command')
    try:
        native_step(root,load_profile(root),source,destination,out,receipt,call)
        receipt['status']='passed-scoped-checks';return receipt
    except BaseException:
        receipt['status']='failed-or-incomplete';raise
    finally:(out/'native-iteration.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf8')

def execute(root,plan):
    root=Path(root).resolve();require(root==Path(plan['root']),'Plan/root mismatch')
    native=plan['mode'] in ('native','release')
    require(not native or platform.system()=='Darwin','Native execution requires macOS/Xcode; planning remains available on Windows')
    require(not (plan['mode']=='native' and plan['selection']['full_native_required']),
      'Uncertain/shared/high-risk changes require the full native release checkpoint; a focused run is refused')
    require(source_snapshot(root)==plan['source'],'Source changed since planning; regenerate the plan')
    environment=native_environment() if native else None
    owned_output(root) # Reject an output parent redirected outside this checkout before any write.
    git(root,'check-ignore','-q','build/iteration/probe') # Output/cache must be ignored already; never edit .gitignore.
    receipt={key:plan[key] for key in ('schema_version','mode','scope','source','changes','base_resolved','selection','full_gate_inventory','limitations')}
    receipt.update(full_acceptance=False,release_eligible=False,commands=[],status='running',
      started_at_utc=datetime.now(timezone.utc).isoformat(),native_build_reused=False,deferred_checks=plan.get('deferred_checks',[]))
    with IterationLock(root):
        require(source_snapshot(root)==plan['source'],'Source changed while acquiring iteration lock')
        out=owned_output(root,'runs',datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:8]);out.mkdir(parents=True)
        started=time.monotonic();expected=plan['source']['sha256']
        def call(command,kind):
            require(source_snapshot(root)['sha256']==expected,'Source changed before the next command')
            log=out/(str(len(receipt['commands'])+1)+'-'+kind+'.log')
            result=run_command(command,root,log,2700 if native else 910,expected,env=environment)
            receipt['commands'].append({**result,'kind':kind,'log_sha256':sha(log) if log.is_file() else None,'reused':False})
            if result.get('aborted'):
                receipt['status']='aborted';raise ValueError(result.get('error','Command interrupted'))
            if result.get('obsolete') or source_snapshot(root)['sha256']!=expected:
                receipt['status']='obsolete-source-changed';raise ValueError('Source changed during validation; discard this iteration receipt')
            require(not result.get('error'),result.get('error','Command incomplete'))
            require(result['exit_code']==0,'Command failed: '+kind)
            if kind in ('core','node','python','native'):
                result['counts']=test_counts(kind,log.read_text(encoding='utf8',errors='replace'))
                receipt['commands'][-1]['counts']=result['counts']
                if kind=='core':
                    ids=verify_core_ids(log.read_text(encoding='utf8',errors='replace'),plan['selection']['selected_core_ids'])
                    require(len(ids)==result['counts']['passed'],'Different Core identity/summary counts')
                    receipt['commands'][-1]['test_ids']=ids
            return log
        try:
            lower_priority()
            if plan['mode']=='native' and plan['commands']:
                native_step(root,plan['profile'],plan['source'],plan['destination'],out,receipt,call,plan['selection'])
            else:
                before=set((root/'build').glob('native-validation-*'))
                for command in plan['commands']:
                    require(source_snapshot(root)==plan['source'],'Source changed before the next command')
                    binding=local_binding(root,command,plan['source']) if plan['mode']=='local' else None
                    previous=cached_local(root,command,binding) if binding and not plan.get('fresh') else None
                    if previous:receipt['commands'].append(previous)
                    else:
                        call(command['argv'],command['kind'])
                        if binding and binding==local_binding(root,command,plan['source']):receipt['commands'][-1]['input_sha256']=binding
                if plan['mode']=='release':
                    evidence=set((root/'build').glob('native-validation-*'))-before
                    require(len(evidence)==1,'Full gate did not produce exactly one new evidence directory')
                    path=evidence.pop();counts=test_counts('native',(path/'test-summary.json').read_text())
                    require(counts['passed']==plan['profile']['full_acceptance']['native']+plan['profile']['full_acceptance']['ui'],'Full native test inventory differs')
                    receipt['existing_full_gate_evidence']=str(path);receipt['full_native_counts']=counts
            require(source_snapshot(root)==plan['source'],'Source changed during validation')
            receipt['status']='passed-scoped-checks' if plan['commands'] else 'docs-only-no-tests'
        except KeyboardInterrupt:
            receipt.update(status='aborted',error='Interrupted by user')
        except (ValueError,OSError,TimeoutError,subprocess.SubprocessError) as error:
            if receipt['status'] not in ('obsolete-source-changed','aborted'):receipt['status']='failed-or-incomplete'
            receipt['error']=str(error)
        finally:
            receipt['elapsed_seconds']=round(time.monotonic()-started,3);receipt['completed_at_utc']=datetime.now(timezone.utc).isoformat()
            receipt['path']=str(out/'receipt.json')
            (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf8')
            save_local_passes(root,receipt)
    return receipt

def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode',nargs='?',default='local',choices=('local','native','release'))
    parser.add_argument('--base',help='Exact commit/ref to compare to HEAD, plus all current index/worktree/untracked changes; no implicit merge-base')
    parser.add_argument('--execute',action='store_true',help='Execute this manual plan; default only plans')
    parser.add_argument('--core-filter',help='Explicit partial Swift filter, local mode only; cannot certify a full gate')
    parser.add_argument('--destination',help='Existing available Simulator UUID for focused native checks')
    parser.add_argument('--runtime',help='Installed iOS Simulator runtime identifier for the existing full gate')
    parser.add_argument('--portable-only',action='store_true',help='Run Node/Python checks; explicitly defer Swift and native validation')
    parser.add_argument('--fresh',action='store_true',help='Execute local checks again even if an unchanged complete pass is available')
    args=parser.parse_args(argv)
    try:
        plan=make_plan(ROOT,args.mode,args.base,args.core_filter,args.destination,args.runtime,args.portable_only,args.fresh)
        print(json.dumps(plan,indent=2),flush=True)
        if args.execute:
            receipt=execute(ROOT,plan);print(json.dumps(receipt,indent=2))
            return 0 if receipt['status'] in ('passed-scoped-checks','docs-only-no-tests') else 1
        return 0
    except (ValueError,OSError,re.error,subprocess.SubprocessError) as error:
        print('Iteration refused: '+str(error),file=sys.stderr);return 2

if __name__=='__main__':raise SystemExit(main())
