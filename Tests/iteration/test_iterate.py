"""Behavior tests for manual selection, cache reuse and truthful iteration receipts."""
import importlib.util
import json
import os
import io
import plistlib
from pathlib import Path
import subprocess
import stat
import tempfile
import unittest
from unittest.mock import patch
from contextlib import redirect_stdout, redirect_stderr

ROOT=Path(__file__).resolve().parents[2]
GIT=r'C:\Program Files\Git\cmd\git.exe' if os.name=='nt' else 'git'
PROFILE={'schema_version':1,'scheme':'ApartmentFinder','project':'ApartmentFinder.xcodeproj','spec':'project.yml',
 'xcode_lock':'Config/Iteration-Package.resolved','wsl_distribution':'Ubuntu',
 'wsl_swift':'/home/linuxandy/.local/share/swiftly/toolchains/6.2.3/usr/bin/swift',
 'core_focus':{'Sources/ApartmentCore/MiniRouteCameraFraming.swift':['MiniRouteCameraFramingTests']},
 'native_focus':{'App/DeliveryMapStyle.swift':['ApartmentFinderUITests/MapAppearanceTests'],
 'Sources/ApartmentCore/MiniRouteCameraFraming.swift':['ApartmentFinderUITests/AutomaticLocationTests','ApartmentFinderUITests/HeadingUpNavigationTests','ApartmentFinderUITests/ApartmentMiniRouteTests']},
 'full_acceptance':{'native':74,'ui':40,'original_pngs':45}}

class IterationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp_base=Path(os.environ.get('AF_ITERATION_TEST_TMP',str(ROOT/'build/it'))).resolve();cls.temp_base.mkdir(parents=True,exist_ok=True)
        cls.temp=Path(tempfile.mkdtemp(prefix='it-',dir=cls.temp_base))
    @classmethod
    def tearDownClass(cls):
        cls.remove_owned(cls.temp,cls.temp_base)
    @staticmethod
    def remove_owned(path,base):
        import shutil
        path=Path(path).resolve();base=Path(base).resolve()
        assert path!=base and path.is_relative_to(base),'Never remove outside an owned unit fixture'
        def writable(function,name,error):
            os.chmod(name,stat.S_IWRITE|stat.S_IREAD);function(name)
        if path.exists():shutil.rmtree(path,onerror=writable)
    def module(self):
        path=ROOT/'scripts/iterate.py'
        self.assertTrue(path.is_file(),'Install the manual iteration wrapper before these behaviors can pass')
        if not hasattr(type(self),'loaded'):
            spec=importlib.util.spec_from_file_location('af_iterate',path);module=importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module);type(self).loaded=module
        return self.loaded
    def fixture(self):
        root=Path(tempfile.mkdtemp(dir=self.temp));self.addCleanup(self.remove_owned,root,self.temp)
        files={'.gitignore':'build/\n.build/\n*.xcodeproj/\n__pycache__/\n',
         'Package.swift':'// fixture\n','Package.resolved':'{"pins":[],"version":2}',
         'project.yml':'name: ApartmentFinder\n','scripts/iteration-profile.json':json.dumps(PROFILE),
         'Config/Iteration-Package.resolved':'{"pins":[],"version":2}',
         'Sources/ApartmentCore/MiniRouteCameraFraming.swift':'// frame\n',
         'Tests/ApartmentCoreTests/MiniRouteCameraFramingTests.swift':'final class MiniRouteCameraFramingTests: XCTestCase { func testOne() {} }',
         'App/DeliveryMapStyle.swift':'// style\n',
         'UITests/MapAppearanceTests.swift':'final class MapAppearanceTests: XCTestCase {\n func testStyle() {}\n}',
         'UITests/AutomaticLocationTests.swift':'final class AutomaticLocationTests: XCTestCase {\n func testGPS() {}\n}',
         'UITests/HeadingUpNavigationTests.swift':'final class HeadingUpNavigationTests: XCTestCase {\n func testHeading() {}\n}',
         'UITests/ApartmentMiniRouteTests.swift':'final class ApartmentMiniRouteTests: XCTestCase {\n func testRoute() {}\n}',
         'NativeTests/StoreTests.swift':'final class StoreTests: XCTestCase {\n func testStore() {}\n}',
         'Tests/data/pack.test.mjs':'// test\n','services/geocoding/worker.test.mjs':'// proxy\n',
         'Tests/iteration/test_fixture.py':'import unittest\n','Tests/signing/test_fixture.py':'import unittest\n',
         'scripts/validate-ios.sh':'#!/bin/bash\nexit 0\n','docs/guide.md':'A plain guide.\n'}
        for name,value in files.items():self.write(root,name,value)
        self.git(root,'init','-q');self.git(root,'add','--all');self.git(root,'commit','-qm','fixture')
        return root
    def git(self,root,*args):
        return subprocess.check_output([GIT,'--no-optional-locks','-c','safe.directory='+root.as_posix(),
          '-c','core.hooksPath='+str(root/'absent-hooks'),'-c','commit.gpgsign=false',
          '-c','user.name=Fixture','-c','user.email=fixture@example.invalid',*args],cwd=root,
          env={**os.environ,'GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':os.devnull},stderr=subprocess.STDOUT).decode().strip()
    def write(self,root,name,value):
        target=root/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_text(value,encoding='utf8');return target
    def changes(self,*paths):return [{'status':'M','paths':[name],'origin':'worktree'} for name in paths]
    def build_products(self,products):
        self.write(products,'App.app/App','binary')
        self.write(products,'Tests.xctest/Tests','test-binary')
        self.write(products,'run.xctestrun','')
        (products/'run.xctestrun').write_bytes(plistlib.dumps({'Tests':{
          'TestBundlePath':'__TESTROOT__/Tests.xctest','TestHostPath':'__TESTROOT__/App.app'}}))
    def test_diff_parser_keeps_both_rename_sides_and_unusual_names(self):
        m=self.module();rows=m.parse_diff(b'R100\0old name\t.md\0docs/new\nname.py\0D\0deleted.swift\0','index')
        self.assertEqual(rows,[{'status':'R100','paths':['old name\t.md','docs/new\nname.py'],'origin':'index'},
                               {'status':'D','paths':['deleted.swift'],'origin':'index'}])
    def test_actual_git_collects_committed_staged_unstaged_untracked_and_deletion(self):
        m=self.module();root=self.fixture();base=self.git(root,'rev-parse','HEAD')
        self.write(root,'docs/committed.md','new');self.git(root,'add','docs/committed.md');self.git(root,'commit','-qm','next')
        self.write(root,'App/DeliveryMapStyle.swift','staged');self.git(root,'add','App/DeliveryMapStyle.swift')
        self.write(root,'App/DeliveryMapStyle.swift','unstaged');(root/'docs/guide.md').unlink();self.write(root,'docs/new.py','print(1)')
        changes,resolved=m.collect_changes(root,base)
        self.assertEqual(resolved,base);self.assertEqual({x['origin'] for x in changes},{'base','index','worktree','untracked'})
        self.assertTrue(any(x['status']=='D' for x in changes))
    def test_staged_rename_old_source_path_prevents_doc_only_classification(self):
        m=self.module();root=self.fixture();self.git(root,'mv','App/DeliveryMapStyle.swift','docs/style.md')
        changes,_=m.collect_changes(root,None);selection=m.classify(root,changes,PROFILE)
        self.assertFalse(selection['docs_only']);self.assertTrue(selection['full_native_required'])
    def test_empty_changes_and_invalid_base_refuse_without_false_success(self):
        m=self.module();root=self.fixture()
        with self.assertRaisesRegex(ValueError,'No changed'):m.make_plan(root,'local')
        with self.assertRaises(ValueError):m.collect_changes(root,'missing-ref')
    def test_doc_only_does_no_native_and_no_executable_disguised_doc_skips(self):
        m=self.module();root=self.fixture()
        self.write(root,'docs/guide.md','Updated prose.\n')
        plan=m.make_plan(root,'local');self.assertTrue(plan['selection']['docs_only']);self.assertEqual(plan['commands'],[])
        for name,text in [('docs/tool.py','pass'),('docs/ci.yml','jobs: {}'),('docs/run.md','#!/usr/bin/python\nprint(1)'),('docs/html.md','<script>alert(1)</script>')]:
            self.write(root,name,text);value=m.classify(root,self.changes(name),PROFILE)
            self.assertFalse(value['docs_only']);self.assertTrue(value['full_native_required'])
    def test_ambiguous_shared_import_persistence_security_build_changes_require_full_gate(self):
        m=self.module();root=self.fixture()
        for name in ('Sources/ApartmentCore/RouteCSV.swift','App/AppStore.swift','ShareExtension/ShareViewController.swift',
          'Config/TestFlight.json','project.yml','.github/workflows/new.yml','docs/unknown.sh','Sources/ApartmentCore/Models.swift'):
            value=m.classify(root,self.changes(name),PROFILE)
            self.assertTrue(value['full_native_required'],name)
    def test_core_edit_requires_full_core_and_native_fallback(self):
        m=self.module();root=self.fixture();value=m.classify(root,self.changes('Sources/ApartmentCore/MiniRouteCameraFraming.swift'),PROFILE)
        self.assertEqual(value['core_filters'],[])
        self.assertIn('core',value['local_suites'])
        self.assertTrue(value['full_native_required'])
    def test_uncertain_path_added_to_focus_never_stays_focused(self):
        m=self.module();root=self.fixture();value=m.classify(root,self.changes('App/DeliveryMapStyle.swift','App/AppStore.swift'),PROFILE)
        self.assertTrue(value['full_native_required'])
    def test_native_test_edit_selects_its_class_but_deletion_requires_full_gate(self):
        m=self.module();root=self.fixture();value=m.classify(root,self.changes('NativeTests/StoreTests.swift'),PROFILE)
        self.assertIn('ApartmentFinderTests/StoreTests',value['native_tests'])
        value=m.classify(root,[{'status':'D','paths':['NativeTests/StoreTests.swift'],'origin':'worktree'}],PROFILE)
        self.assertTrue(value['full_native_required'])
    def test_data_changes_include_core_validation_and_node_dependency_suites(self):
        m=self.module();root=self.fixture();value=m.classify(root,self.changes('data/locations.geojson'),PROFILE)
        self.assertTrue({'core','node'}.issubset(value['local_suites']));self.assertTrue(value['full_native_required'])
    def test_profile_itself_is_validation_infrastructure_and_not_a_doc_skip(self):
        m=self.module();root=self.fixture();value=m.classify(root,self.changes('scripts/iteration-profile.json'),PROFILE)
        self.assertEqual(value['local_suites'],['iteration']);self.assertTrue(value['full_native_required'])
    def test_manual_filter_is_explicitly_partial_and_never_release_acceptance(self):
        m=self.module();root=self.fixture();self.write(root,'docs/guide.md','new')
        plan=m.make_plan(root,'local',core_filter='MiniRouteCameraFramingTests')
        self.assertEqual(plan['scope'],'custom-local');self.assertFalse(plan['full_acceptance'])
        with self.assertRaises(ValueError):m.make_plan(root,'release',core_filter='Anything',runtime='runtime')
    def test_windows_native_refusal_precedes_native_process_or_cache_write(self):
        m=self.module();root=self.fixture();self.write(root,'App/DeliveryMapStyle.swift','new')
        plan=m.make_plan(root,'native',destination='device-uuid')
        with patch.object(m.platform,'system',return_value='Windows'),patch.object(m,'run_command',side_effect=AssertionError('native process')):
            with self.assertRaisesRegex(ValueError,'macOS'):m.execute(root,plan)
        self.assertFalse((root/'build').exists())
    def test_release_plan_only_calls_existing_unsigned_full_gate(self):
        m=self.module();root=self.fixture();self.write(root,'project.yml','new')
        plan=m.make_plan(root,'release',runtime='runtime-id')
        self.assertEqual(len(plan['commands']),1);self.assertEqual(Path(plan['commands'][0]['argv'][1]),root/'scripts/validate-ios.sh')
        for forbidden in ('gh ','workflow run','testflight-build','testflight-upload','archive','budget'):
            self.assertNotIn(forbidden,' '.join(plan['commands'][0]['argv']))
        self.assertFalse(plan['full_acceptance'])
    def test_source_snapshot_detects_unstaged_untracked_deletions_and_pin_changes(self):
        m=self.module();root=self.fixture();before=m.source_snapshot(root)
        for path,value in [('App/DeliveryMapStyle.swift','new'),('docs/untracked.md','new'),('Package.resolved','changed')]:
            self.write(root,path,value);after=m.source_snapshot(root);self.assertNotEqual(before['sha256'],after['sha256']);before=after
        (root/'Package.swift').unlink();self.assertNotEqual(before['sha256'],m.source_snapshot(root)['sha256'])
    def test_cache_requires_exact_sources_tools_sdk_architecture_dependencies_and_products(self):
        m=self.module();root=self.fixture();cache=root/'build/cache';products=cache/'DerivedData/Build/Products';products.mkdir(parents=True)
        self.build_products(products);binary=products/'App.app/App'
        self.write(root,'ApartmentFinder.xcodeproj/project.pbxproj','generated')
        tools={'xcode':'26.2','sdk':'26.2','architecture':'arm64','swift':'6.2.3','developer_dir':'/Xcode'}
        original=m.fingerprint(root,PROFILE,tools,m.source_snapshot(root));m.save_cache(root,PROFILE,cache,original)
        self.assertTrue(m.reusable(root,PROFILE,cache,original))
        for key in ('HOME','TMPDIR','PATH'):
            environment=m.native_environment();environment[key]='different launch path'
            transient=m.fingerprint(root,PROFILE,{**tools,'destination':'a-disposable-uuid'},m.source_snapshot(root),environment)
            self.assertTrue(m.reusable(root,PROFILE,cache,transient),key)
        for key in ('xcode','sdk','architecture','swift','developer_dir'):
            other=m.fingerprint(root,PROFILE,{**tools,key:'different'},m.source_snapshot(root));self.assertFalse(m.reusable(root,PROFILE,cache,other))
        binary.write_text('tampered');self.assertFalse(m.reusable(root,PROFILE,cache,original));binary.write_text('binary')
        self.write(root,'Sources/ApartmentCore/MiniRouteCameraFraming.swift','changed')
        changed=m.fingerprint(root,PROFILE,tools,m.source_snapshot(root));self.assertFalse(m.reusable(root,PROFILE,cache,changed))
        self.assertEqual(original['compatibility_sha256'],changed['compatibility_sha256'],'Source-only edits retain incremental DerivedData but require rebuilding')
        self.write(root,'Package.resolved','changed pins');pins=m.fingerprint(root,PROFILE,tools,m.source_snapshot(root))
        self.assertNotEqual(original['compatibility_sha256'],pins['compatibility_sha256'])
    def test_missing_products_or_changed_generated_project_cannot_reuse(self):
        m=self.module();root=self.fixture();cache=root/'build/cache';products=cache/'DerivedData/Build/Products';products.mkdir(parents=True)
        self.build_products(products)
        project=self.write(root,'ApartmentFinder.xcodeproj/project.pbxproj','generated')
        value=m.fingerprint(root,PROFILE,{'sdk':'26.2'},m.source_snapshot(root));m.save_cache(root,PROFILE,cache,value)
        project.write_text('changed');self.assertFalse(m.reusable(root,PROFILE,cache,value));project.write_text('generated')
        (products/'run.xctestrun').unlink();self.assertFalse(m.reusable(root,PROFILE,cache,value))
    def test_scoped_lock_blocks_duplicate_but_never_removes_other_owners_lock(self):
        m=self.module();root=self.fixture()
        with m.IterationLock(root,'one'):
            with self.assertRaisesRegex(ValueError,'lock'): 
                with m.IterationLock(root,'two'):pass
            self.assertEqual(json.loads((root/'build/iteration/run.lock').read_text())['token'],'one')
        self.assertFalse((root/'build/iteration/run.lock').exists())
    def test_zero_tests_or_failed_or_unknown_summaries_never_pass(self):
        m=self.module()
        for kind,body in [('core','Executed 0 tests, with 0 failures'),('node','# tests 0\n# pass 0\n# fail 0'),
          ('python','Ran 0 tests in 0s\nOK'),('native','{}'),('native','{"totalTestCount":1,"passedTests":0,"failedTests":1,"skippedTests":0,"expectedFailures":0}')]:
            with self.assertRaises(ValueError):m.test_counts(kind,body)
        self.assertEqual(m.test_counts('core','Executed 8 tests, with 0 failures (0 unexpected)')['passed'],8)
    def test_source_change_during_command_marks_obsolete_and_stops_following_work(self):
        m=self.module();root=self.fixture();self.write(root,'docs/guide.md','new');plan=m.make_plan(root,'local',core_filter='MiniRouteCameraFramingTests')
        def fake(argv,cwd,log,timeout,expected,env=None):
            self.write(root,'App/DeliveryMapStyle.swift','changed while testing');Path(log).write_text('Executed 8 tests, with 0 failures (0 unexpected)')
            return {'exit_code':0,'elapsed_seconds':.01,'log':str(log),'argv':argv}
        with patch.object(m,'run_command',side_effect=fake), patch.object(m,'local_binding',return_value=None):
            receipt=m.execute(root,plan)
        self.assertEqual(receipt['status'],'obsolete-source-changed');self.assertFalse(receipt['full_acceptance'])
    def test_plan_is_read_only_and_all_receipts_are_outside_release_evidence(self):
        m=self.module();root=self.fixture();self.write(root,'App/DeliveryMapStyle.swift','new');before=m.source_snapshot(root)
        value=m.make_plan(root,'native',destination='device-uuid')
        self.assertEqual(before,m.source_snapshot(root));self.assertFalse((root/'build').exists());self.assertFalse(value['full_acceptance'])
    def test_stale_filter_and_missing_node_target_refuse_before_execution(self):
        m=self.module();root=self.fixture();self.write(root,'docs/guide.md','new')
        with self.assertRaisesRegex(ValueError,'matches no existing'):m.make_plan(root,'local',core_filter='DeletedOrMisspelledTests')
        self.write(root,'data/new.json','{}');(root/'services/geocoding/worker.test.mjs').unlink()
        with self.assertRaisesRegex(ValueError,'absent'):m.make_plan(root,'local')
    def test_swift_package_options_follow_the_test_subcommand(self):
        m=self.module();root=self.fixture();self.write(root,'docs/guide.md','new')
        command=m.make_plan(root,'local',core_filter='MiniRouteCameraFramingTests')['commands'][0]['argv']
        self.assertLess(command.index('test'),command.index('--package-path'))
    def test_multiple_existing_core_classes_in_one_file_are_selectable(self):
        m=self.module();root=self.fixture()
        self.write(root,'Tests/ApartmentCoreTests/Multi.swift','final class OneTests: XCTestCase { func testOne() {} }\nfinal class TwoTests: XCTestCase { func testTwo() {} }')
        ids=m.test_ids(root,'Tests/ApartmentCoreTests');self.assertIn('OneTests/testOne',ids);self.assertIn('TwoTests/testTwo',ids)
        self.assertNotIn('OneTests/testTwo',ids)
    def test_planning_refuses_a_shared_edit_arriving_after_path_collection(self):
        m=self.module();root=self.fixture();self.write(root,'App/DeliveryMapStyle.swift','new');original=m.collect_changes
        def changed(*args):
            result=original(*args);self.write(root,'App/AppStore.swift','new shared import logic');return result
        with patch.object(m,'collect_changes',side_effect=changed):
            with self.assertRaisesRegex(ValueError,'changed'):m.make_plan(root,'native',destination='device-uuid')
    def test_index_only_change_is_part_of_the_snapshot_identity(self):
        m=self.module();root=self.fixture();before=m.source_snapshot(root)
        path=root/'App/DeliveryMapStyle.swift';old=path.read_text();path.write_text('staged')
        self.git(root,'add','App/DeliveryMapStyle.swift');path.write_text(old)
        self.assertNotEqual(before['sha256'],m.source_snapshot(root)['sha256'])
    def test_unreviewed_profile_mapping_never_narrows_high_risk_changes(self):
        m=self.module();root=self.fixture();profile=json.loads(json.dumps(PROFILE))
        profile['native_focus']['App/AppStore.swift']=['ApartmentFinderUITests/MapAppearanceTests']
        profile['core_focus']['Sources/ApartmentCore/Models.swift']=['MiniRouteCameraFramingTests']
        for name in ('App/AppStore.swift','Sources/ApartmentCore/Models.swift'):
            self.assertTrue(m.classify(root,self.changes(name),profile)['full_native_required'])
    def test_every_mapped_class_must_exist_not_just_one_real_alternative(self):
        m=self.module();root=self.fixture();profile=json.loads(json.dumps(PROFILE))
        profile['core_focus']['Sources/ApartmentCore/MiniRouteCameraFraming.swift'].append('StaleTests')
        self.write(root,'scripts/iteration-profile.json',json.dumps(profile))
        with self.assertRaisesRegex(ValueError,'Mapped core class is absent: StaleTests'):m.make_plan(root,'local')
    def test_singular_core_result_passes_but_expected_failure_is_incomplete(self):
        m=self.module();self.assertEqual(m.test_counts('core','Executed 1 test, with 0 failures')['passed'],1)
        with self.assertRaises(ValueError):m.test_counts('core','Expected failure was recorded\nExecuted 8 tests, with 0 failures')
    def test_native_identity_tree_requires_every_requested_test_and_no_substitutions(self):
        m=self.module();self.assertTrue(hasattr(m,'verify_native_ids'),'Bind actual focused native identities')
        expected=['ApartmentFinderUITests/OneTests/testOne','ApartmentFinderTests/TwoTests/testTwo']
        tree={'testNodes':[{'nodeType':'Test Case','nodeIdentifier':name+'()','result':'Passed'} for name in expected]}
        self.assertEqual(m.verify_native_ids(tree,expected),sorted(expected))
        with self.assertRaises(ValueError):m.verify_native_ids({'testNodes':tree['testNodes'][:1]},expected)
        tree['testNodes'][1]['nodeIdentifier']='ApartmentFinderUITests/OneTests/testOther()'
        with self.assertRaises(ValueError):m.verify_native_ids(tree,expected)
    def test_core_identity_results_require_the_exact_selected_methods(self):
        m=self.module();body="Test Case 'OneTests.testOne' started at 2026-10-18 00:00:00.000\nTest Case 'OneTests.testOne' passed (0.01 seconds)\n"
        self.assertEqual(m.verify_core_ids(body,['OneTests/testOne']),['OneTests/testOne'])
        with self.assertRaises(ValueError):m.verify_core_ids(body,['OneTests/testOne','TwoTests/testTwo'])
        with self.assertRaises(ValueError):m.verify_core_ids(body,['OneTests/testOther'])
        with self.assertRaises(ValueError):m.verify_core_ids(body+body,['OneTests/testOne'])
    def test_external_xcode_config_override_cannot_reuse_a_build(self):
        m=self.module();root=self.fixture();override=self.write(root,'build/override.xcconfig','OTHER_SWIFT_FLAGS=-DCHANGED')
        with patch.dict(os.environ,{'XCODE_XCCONFIG_FILE':str(override)}):
            with self.assertRaisesRegex(ValueError,'override|configuration'):m.fingerprint(root,PROFILE,{'sdk':'26.2'},m.source_snapshot(root))
    def test_staged_deletion_of_executable_markdown_is_not_docs_only(self):
        m=self.module();root=self.fixture();self.git(root,'update-index','--chmod=+x','docs/guide.md');self.git(root,'commit','-qm','executable markdown')
        self.git(root,'rm','-f','docs/guide.md');changes,_=m.collect_changes(root,None)
        self.assertFalse(m.classify(root,changes,PROFILE)['docs_only'])
    def test_timeout_returns_the_attempted_command_exit_and_elapsed_evidence(self):
        m=self.module();root=self.fixture()
        class Child:
            pid=123456;returncode=None
            def poll(self):return self.returncode
            def terminate(self):self.returncode=-15
            def kill(self):self.returncode=-9
            def wait(self,timeout=None):return self.returncode
        child=Child()
        with patch.object(m.subprocess,'Popen',return_value=child),patch.object(m.os,'killpg',side_effect=lambda *x:child.terminate(),create=True):
            value=m.run_command(['owned-test-command'],root,root/'timeout.log',0,'unused')
        self.assertEqual(value['argv'],['owned-test-command']);self.assertIsNotNone(value['exit_code']);self.assertIn('elapsed_seconds',value)
        self.assertIn('timeout',value['error'].lower())
    def test_process_start_failure_and_interrupt_keep_attempt_evidence(self):
        m=self.module();root=self.fixture()
        for error,name in ((OSError('missing tool'),'missing'),(KeyboardInterrupt(),'interrupt')):
            with patch.object(m.subprocess,'Popen',side_effect=error):
                value=m.run_command(['owned-command'],root,root/(name+'.log'),1,'unused')
            self.assertEqual(value['argv'],['owned-command']);self.assertIsNone(value['exit_code'])
            self.assertIn('elapsed_seconds',value);self.assertIn('error',value)
            self.assertEqual(value['aborted'],name=='interrupt')
    def test_native_environment_discards_unbound_build_overrides(self):
        m=self.module()
        with patch.dict(os.environ,{'SWIFT_EXEC':'/unbound/swift','SDKROOT':'/unbound/sdk'}):
            env=m.native_environment();self.assertNotIn('SWIFT_EXEC',env);self.assertNotIn('SDKROOT',env)
    def test_wsl_command_has_its_own_guest_deadline(self):
        m=self.module()
        command=m.swift_prefix(Path('C:/project'),PROFILE,'swift','Windows') if os.name=='nt' else None
        if command is not None:
            self.assertIn('/usr/bin/timeout',command);self.assertIn('--kill-after=5s',command);self.assertIn('900s',command)
    def test_native_pipeline_builds_once_and_only_reuses_exact_unchanged_products(self):
        m=self.module();root=self.fixture();self.write(root,'App/DeliveryMapStyle.swift','new');calls=[]
        tools={'sdk':'26.2','xcode':'26.2','architecture':'arm64','swift':'6.2.3'}
        def fake(argv,cwd,log,timeout,expected,env=None):
            calls.append(argv)
            if argv[0]=='xcodegen':self.write(root,'ApartmentFinder.xcodeproj/project.pbxproj','generated')
            if 'build-for-testing' in argv:
                derived=Path(argv[argv.index('-derivedDataPath')+1]);products=derived/'Build/Products'
                self.build_products(products)
            if 'test-without-building' in argv:self.write(Path(argv[argv.index('-resultBundlePath')+1]),'original','original result')
            if argv[0]=='xcrun' and 'tests'==argv[4]:text=json.dumps({'testNodes':[{'nodeType':'Test Case','nodeIdentifier':'ApartmentFinderUITests/MapAppearanceTests/testStyle()','result':'Passed'}]})
            else:text=json.dumps({'totalTestCount':1,'passedTests':1,'failedTests':0,'skippedTests':0,'expectedFailures':0}) if argv[0]=='xcrun' else 'ok'
            Path(log).write_text(text)
            return {'exit_code':0,'elapsed_seconds':.01,'log':str(log),'argv':argv}
        with patch.object(m.platform,'system',return_value='Darwin'),patch.object(m,'observe_native',return_value=tools),\
             patch.object(m,'run_command',side_effect=fake):
            plan=m.make_plan(root,'native',destination='device-uuid');one=m.execute(root,plan)
            self.remove_owned(root/'ApartmentFinder.xcodeproj',root)
            two=m.execute(root,plan)
            self.assertEqual(one['status'],'passed-scoped-checks',json.dumps(one));self.assertFalse(one['native_build_reused'])
            self.assertTrue(two['native_build_reused']);self.assertEqual(sum('build-for-testing' in x for x in calls),1)
            cache=root/'build/iteration/native-cache'/two['cache_fingerprint']['compatibility_sha256'][:24]
            (cache/'DerivedData/Build/Products/App.app/App').write_text('tampered')
            three=m.execute(root,plan);self.assertFalse(three['native_build_reused'])
            self.assertEqual(sum('build-for-testing' in x for x in calls),2)
            self.write(root,'App/DeliveryMapStyle.swift','changed source')
            four=m.execute(root,m.make_plan(root,'native',destination='device-uuid'))
            self.assertFalse(four['native_build_reused']);self.assertEqual(sum('build-for-testing' in x for x in calls),3)
            self.assertFalse(any(receipt['full_acceptance'] for receipt in (one,two,three,four)))

    def test_default_and_portable_only_cli_produce_usable_local_plans(self):
        m=self.module();root=self.fixture()
        self.write(root,'Sources/ApartmentCore/MiniRouteCameraFraming.swift','changed core')
        for arguments in ([],['--portable-only']):
            output=io.StringIO()
            with patch.object(m,'ROOT',root),redirect_stdout(output),redirect_stderr(io.StringIO()):
                try:code=m.main(arguments)
                except SystemExit as error:code=error.code
            self.assertEqual(code,0,'Default invocation must be a local plan, not an argparse failure')
            plan=json.loads(output.getvalue());self.assertEqual(plan['mode'],'local')
            if arguments:
                self.assertFalse(any(c['kind'] in ('core','syntax') for c in plan['commands']))
                self.assertTrue(plan['deferred_checks']);self.assertFalse(plan['full_acceptance'])
                self.assertTrue({'node','python'}.issubset({c['kind'] for c in plan['commands']}))

    def test_local_pass_reuse_binds_relevant_tests_tools_and_original_logs(self):
        m=self.module();root=self.fixture();self.write(root,'services/geocoding/worker.mjs','changed');calls=[]
        def fake(argv,cwd,log,timeout,expected,env=None):
            calls.append(argv)
            body='TAP version 13\n# Subtest: proxy\nok 1 - proxy\n# tests 1\n# pass 1\n# fail 0\n# cancelled 0\n# skipped 0\n# todo 0\n' if '--test' in argv else 'Ran 1 test in 0.01s\n\nOK\n'
            Path(log).write_text(body)
            return {'exit_code':0,'elapsed_seconds':.01,'log':str(log),'argv':argv}
        with patch.object(m,'run_command',side_effect=fake), patch.dict(os.environ, {key:'' for key in
          ('NODE_OPTIONS','NODE_PATH','PYTHONPATH','PYTHONHOME','SWIFT_EXEC','SDKROOT','XCODE_XCCONFIG_FILE')}):
            first=m.execute(root,m.make_plan(root,'local',portable_only=True))
            second=m.execute(root,m.make_plan(root,'local',portable_only=True))
            node=lambda receipt:next(c for c in receipt['commands'] if c['kind']=='node')
            self.assertTrue(node(second).get('reused',False),'An unchanged passed check must not execute again')
            self.write(root,'UITests/MapAppearanceTests.swift',(root/'UITests/MapAppearanceTests.swift').read_text()+'\n// unrelated UI edit\n')
            third=m.execute(root,m.make_plan(root,'local',portable_only=True))
            self.assertTrue(node(third).get('reused',False),'UI-only edits must not invalidate unchanged Node checks')
            Path(node(first)['log']).write_text('tampered original proof')
            fourth=m.execute(root,m.make_plan(root,'local',portable_only=True))
            self.assertFalse(node(fourth).get('reused',False),'Tampered logs must execute again')
            self.write(root,'services/geocoding/worker.test.mjs','changed test source')
            fifth=m.execute(root,m.make_plan(root,'local',portable_only=True))
            self.assertFalse(node(fifth).get('reused',False),'Changed tests cannot inherit an older pass')

    def test_failed_local_attempt_never_supplies_a_cached_pass(self):
        m=self.module();root=self.fixture();self.write(root,'services/geocoding/worker.mjs','changed');fail=[True]
        def fake(argv,cwd,log,timeout,expected,env=None):
            body='# tests 1\n# pass 1\n# fail 0\n# cancelled 0\n# skipped 0\n# todo 0\n' if '--test' in argv else 'Ran 1 test in 0.01s\n\nOK\n'
            Path(log).write_text(body)
            return {'exit_code':1 if fail[0] else 0,'elapsed_seconds':.01,'log':str(log),'argv':argv}
        with patch.object(m,'run_command',side_effect=fake):
            one=m.execute(root,m.make_plan(root,'local'));fail[0]=False
            two=m.execute(root,m.make_plan(root,'local'))
        self.assertEqual(one['status'],'failed-or-incomplete')
        self.assertFalse(any(c.get('reused',False) for c in two['commands']))

    def test_xctestrun_cannot_certify_a_missing_referenced_bundle(self):
        m=self.module();root=self.fixture();cache=root/'build/cache';products=cache/'DerivedData/Build/Products'
        self.build_products(products);self.write(root,'ApartmentFinder.xcodeproj/project.pbxproj','generated')
        (products/'run.xctestrun').write_bytes(plistlib.dumps({'Tests':{'TestBundlePath':'__TESTROOT__/Missing.xctest'}}))
        value=m.fingerprint(root,PROFILE,{'sdk':'26.2'},m.source_snapshot(root))
        with self.assertRaisesRegex(ValueError,'bundle|product|reference'):m.save_cache(root,PROFILE,cache,value)

    def test_xctestrun_checks_hosts_ui_apps_dependencies_and_bound_platform_bytes(self):
        m=self.module();root=self.fixture();cache=root/'build/cache';products=cache/'DerivedData/Build/Products'
        self.build_products(products);self.write(root,'ApartmentFinder.xcodeproj/project.pbxproj','generated')
        for key in ('TestHostPath','UITargetAppPath','DependentProductPaths'):
            target={'TestBundlePath':'__TESTROOT__/Tests.xctest',key:['__TESTROOT__/Missing.app'] if key=='DependentProductPaths' else '__TESTROOT__/Missing.app'}
            (products/'run.xctestrun').write_bytes(plistlib.dumps({'Tests':target}))
            with self.assertRaisesRegex(ValueError,'reference'):m.save_cache(root,PROFILE,cache,m.fingerprint(root,PROFILE,{},m.source_snapshot(root)))
        platform=root/'build/Xcode/Platforms';agent=self.write(platform,'iPhoneSimulator.platform/agent','platform runner')
        target={'TestBundlePath':'__TESTROOT__/Tests.xctest','TestHostPath':'__PLATFORMS__/iPhoneSimulator.platform/agent'}
        (products/'run.xctestrun').write_bytes(plistlib.dumps({'TestConfigurations':[{'TestTargets':[target]}]}))
        value=m.fingerprint(root,PROFILE,{'platforms_directory':str(platform)},m.source_snapshot(root))
        m.save_cache(root,PROFILE,cache,value);self.assertTrue(m.reusable(root,PROFILE,cache,value))
        agent.write_text('different platform bytes');self.assertFalse(m.reusable(root,PROFILE,cache,value))

    def test_failed_native_tests_keep_build_products_and_preserve_original_results(self):
        m=self.module();root=self.fixture();self.write(root,'App/DeliveryMapStyle.swift','new');calls=[]
        def fake(argv,cwd,log,timeout,expected,env=None):
            calls.append(argv)
            if argv[0]=='xcodegen':self.write(root,'ApartmentFinder.xcodeproj/project.pbxproj','generated')
            if 'build-for-testing' in argv:self.build_products(Path(argv[argv.index('-derivedDataPath')+1])/'Build/Products')
            if 'test-without-building' in argv:
                result=Path(argv[argv.index('-resultBundlePath')+1]);self.write(result,'original-result','original bytes')
            if argv[:4]==['xcrun','xcresulttool','export','attachments']:
                output=Path(argv[argv.index('--output-path')+1]);self.write(output,'manifest.json','[]')
            Path(log).write_text('interrupted' if 'test-without-building' in argv else '{}')
            return {'exit_code':1 if 'test-without-building' in argv else 0,'elapsed_seconds':.01,'log':str(log),'argv':argv}
        with patch.object(m.platform,'system',return_value='Darwin'),patch.object(m,'observe_native',return_value={'sdk':'26.2'}),patch.object(m,'run_command',side_effect=fake):
            result=m.execute(root,m.make_plan(root,'native',destination='device-uuid'))
        self.assertEqual(result['status'],'failed-or-incomplete')
        cache=root/'build/iteration/native-cache'/result['cache_fingerprint']['compatibility_sha256'][:24]
        self.assertTrue((cache/'ready.json').is_file(),'A test failure must not invalidate unchanged successful build products')
        out=Path(result['path']).parent
        self.assertEqual((out/'focused.xcresult/original-result').read_text(),'original bytes')
        self.assertTrue(any(argv[:4]==['xcrun','xcresulttool','export','attachments'] for argv in calls))
        self.assertFalse(result['full_acceptance'])

    def test_optional_products_yield_to_original_results_within_artifact_bound(self):
        m=self.module();root=self.fixture();out=root/'build/iteration/runs/test';out.mkdir(parents=True)
        original=self.write(out,'focused.xcresult/original','x'*100)
        optional=self.write(out,'build-products.tar','p'*500)
        preserve=getattr(m,'bound_artifact',None)
        if preserve is None:self.fail('Native preservation needs a real bounded artifact decision')
        value=preserve(out,optional,limit=300)
        self.assertTrue(original.is_file());self.assertFalse(optional.exists())
        self.assertEqual(value['retention_days'],1);self.assertTrue(value['within_limit'])
        self.assertFalse(value['complete'])

    def test_full_native_step_uses_existing_build_pipeline_and_runs_every_native_id(self):
        m=self.module();root=self.fixture();calls=[];evidence=root/'build/full-evidence';evidence.mkdir(parents=True)
        profile={**PROFILE,'full_acceptance':{'native':1,'ui':4,'original_pngs':45}}
        self.write(root,'scripts/iteration-profile.json',json.dumps(profile))
        selected=['ApartmentFinderTests/'+i for i in m.test_ids(root,'NativeTests')]+['ApartmentFinderUITests/'+i for i in m.test_ids(root,'UITests')]
        def fake(argv,cwd,log,timeout,expected,env=None):
            calls.append(argv)
            if argv[0]=='xcodegen':self.write(root,'ApartmentFinder.xcodeproj/project.pbxproj','generated')
            if 'build-for-testing' in argv:self.build_products(Path(argv[argv.index('-derivedDataPath')+1])/'Build/Products')
            if 'test-without-building' in argv:self.write(Path(argv[argv.index('-resultBundlePath')+1]),'original','original')
            if argv[:4]==['xcrun','xcresulttool','export','attachments']:
                self.write(Path(argv[argv.index('--output-path')+1]),'manifest.json','[]');text='exported'
            elif argv[0]=='xcrun' and 'tests' in argv:
                text=json.dumps({'testNodes':[{'nodeType':'Test Case','nodeIdentifier':i+'()','result':'Passed'} for i in selected]})
            elif argv[0]=='xcrun':text=json.dumps({'totalTestCount':5,'passedTests':5,'failedTests':0,'skippedTests':0,'expectedFailures':0})
            else:text='built'
            Path(log).write_text(text);return {'exit_code':0,'elapsed_seconds':.01,'log':str(log),'argv':argv}
        run=getattr(m,'full_native_step',None)
        if run is None:self.fail('The full gate needs the same verified build/capture implementation')
        with patch.object(m.platform,'system',return_value='Darwin'),patch.object(m,'observe_native',return_value={'sdk':'26.2'}),patch.object(m,'run_command',side_effect=fake):
            value=run(root,evidence,'device-uuid')
        self.assertEqual(value['test_ids'],sorted(selected))
        self.assertTrue((evidence/'native-tests.xcresult/original').is_file())
        self.assertFalse(any(any(a.startswith('-only-testing:') for a in argv) for argv in calls))
        self.assertTrue(any('build-for-testing' in argv for argv in calls))

if __name__=='__main__':unittest.main(verbosity=2)
