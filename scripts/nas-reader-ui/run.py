#!/usr/bin/env python3
"""Real reader recovery UI against the generated loopback-only SMB fixture controller."""
import argparse
import fcntl
import json
from pathlib import Path
import subprocess
import tempfile
import time
import uuid
import yaml

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--udid', required=True)
parser.add_argument('--result', required=True, type=Path)
parser.add_argument('--only', action='append', default=[])
parser.add_argument('--orientation', choices=['portrait', 'landscape'], default='portrait')
parser.add_argument('--root', type=Path, default=Path('/tmp/mango-earmark-smb-fixtures'))
args = parser.parse_args()
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
device = next((d for group in devices['devices'].values() for d in group if d['udid'] == args.udid), None)
if not device or 'Audit' not in device['name']:
    parser.error('Use a dedicated Audit simulator, never a physical device')
lock = Path('/tmp/mango-nas-reader-ui-' + args.udid + '.lock').open('a')
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    parser.error('A reader UI run is already active on this simulator')
args.result = args.result.resolve()
if args.result.exists():
    parser.error('Result path exists')
if not (args.root / '.service-control/session.json').exists():
    parser.error('Start scripts/nas-audit/service_control.py first')
control = args.root / '.service-control'
nonce = json.loads((control / 'session.json').read_text())['nonce']

def restore_fixture_service():
    if not (control / 'session.json').exists() or json.loads((control / 'session.json').read_text())['nonce'] != nonce:
        raise RuntimeError('Owned fixture control session changed during UI test')
    identity = str(uuid.uuid4())
    request = control / 'reader-ui-request.new'
    request.write_text(json.dumps({'id': identity, 'nonce': nonce, 'action': 'start'}))
    request.replace(control / 'request.json')
    for _ in range(100):
        try:
            reply = json.loads((control / 'response.json').read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            time.sleep(.05)
            continue
        if reply['id'] == identity and reply['nonce'] == nonce and reply['running']:
            print('Fixture service restored', flush=True)
            return
        time.sleep(.05)
    raise RuntimeError('Owned fixture service did not acknowledge restoration')
repo = Path(__file__).resolve().parents[2]
work = Path(tempfile.mkdtemp(prefix='mango-nas-reader-ui-'))
print('Artifacts:', work, flush=True)
for name in ['Mango', 'MangoTests', 'MangoWidgets', 'Shared', 'Config']:
    (work / name).symlink_to(repo / name, target_is_directory=True)
for name in ['AuditApp.swift', 'FlowTests.swift']:
    (work / name).symlink_to(Path(__file__).with_name(name))
(work / 'FixtureServiceControl.swift').symlink_to(repo / 'scripts/nas-audit/FixtureServiceControl.swift')
(work / 'FixtureConnectionReset.swift').symlink_to(repo / 'scripts/nas-audit/FixtureConnectionReset.swift')
spec = yaml.safe_load((repo / 'project.yml').read_text())
for target in spec['targets'].values():
    base = target.get('settings', {}).get('base', {})
    for key in list(base):
        if 'CODE_SIGN_ENTITLEMENTS' in key:
            del base[key]
    if 'PRODUCT_BUNDLE_IDENTIFIER' in base:
        base['PRODUCT_BUNDLE_IDENTIFIER'] = base['PRODUCT_BUNDLE_IDENTIFIER'].replace('com.vanities.mango', 'com.vanities.mangonasreaderqa')
for source in spec['targets']['Mango']['sources']:
    if source['path'] == 'Mango':
        source.setdefault('excludes', []).append('App/MangoApp.swift')
spec['targets']['Mango']['sources'].append({'path': 'AuditApp.swift'})
spec['targets']['NASReaderFlowTests'] = {
    'type': 'bundle.ui-testing', 'platform': 'iOS', 'sources': ['FlowTests.swift', 'FixtureServiceControl.swift', 'FixtureConnectionReset.swift'],
    'dependencies': [{'target': 'Mango'}],
    'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'com.vanities.mangoNASReaderFlowTests',
                          'GENERATE_INFOPLIST_FILE': 'YES', 'TEST_TARGET_NAME': 'Mango'}}}
spec['schemes']['ReaderRecoveryQA'] = {
    'build': {'targets': {'Mango': 'all', 'NASReaderFlowTests': ['test']}},
    'test': {'targets': ['NASReaderFlowTests'], 'environmentVariables': {
        'SMB_AUDIT_ROOT': str(args.root.resolve()), 'QA_ORIENTATION': args.orientation}}}
(work / 'project.yml').write_text(yaml.safe_dump(spec, sort_keys=False))
subprocess.run(['xcodegen', 'generate', '--spec', str(work / 'project.yml')], check=True)
command = ['xcodebuild', 'test', '-project', str(work / 'Mango.xcodeproj'), '-scheme', 'ReaderRecoveryQA',
           '-destination', 'platform=iOS Simulator,id=' + args.udid, '-parallel-testing-enabled', 'NO',
           '-collect-test-diagnostics', 'never', '-derivedDataPath', '/tmp/Mango-NASReaderUIDerivedData',
           '-resultBundlePath', str(args.result)]
for method in args.only:
    command += ['-only-testing:NASReaderFlowTests/NASReaderFlowTests/' + method]
try:
    with args.result.with_suffix('.log').open('w') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
finally:
    restore_fixture_service()
raise SystemExit(result.returncode)
