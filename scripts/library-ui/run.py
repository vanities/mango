#!/usr/bin/env python3
"""Native library audit on a dedicated simulator, with a separate generated-only QA app."""
import argparse
import fcntl
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import yaml

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--udid', required=True, help='Dedicated simulator with Audit in its name')
parser.add_argument('--result', required=True, type=Path)
parser.add_argument('--orientation', choices=['portrait', 'landscape'], default='portrait')
parser.add_argument('--only', action='append', default=[])
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
device = next((d for group in devices['devices'].values() for d in group if d['udid'] == args.udid), None)
if not device or 'Audit' not in device['name']:
    parser.error('Use a dedicated Audit simulator, never a personal device')
lock = Path('/tmp/mango-library-ui-' + args.udid + '.lock').open('a')
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    parser.error('Another library UI run is active on this simulator')
args.result = args.result.resolve()
if args.result.exists():
    parser.error('Result already exists')
fixtures = repo / 'demo-library'
if not fixtures.is_dir():
    parser.error('Generate invented books first with scripts/make-demo-library.py')
bundle = 'com.vanities.mangolibraryaudit'
work = Path(tempfile.mkdtemp(prefix='mango-library-audit-'))
print('Artifacts:', work, flush=True)
for child in ['Mango', 'MangoTests', 'MangoWidgets', 'Shared', 'Config']:
    (work / child).symlink_to(repo / child, target_is_directory=True)
(work / 'FlowTests.swift').symlink_to(Path(__file__).with_name('FlowTests.swift'))
spec = yaml.safe_load((repo / 'project.yml').read_text())
for target in spec['targets'].values():
    base = target.get('settings', {}).get('base', {})
    for key in list(base):
        if 'CODE_SIGN_ENTITLEMENTS' in key:
            del base[key]
    if 'PRODUCT_BUNDLE_IDENTIFIER' in base:
        base['PRODUCT_BUNDLE_IDENTIFIER'] = base['PRODUCT_BUNDLE_IDENTIFIER'].replace('com.vanities.mango', bundle)
spec['targets']['FlowUITests'] = {
    'type': 'bundle.ui-testing', 'platform': 'iOS', 'sources': ['FlowTests.swift'],
    'dependencies': [{'target': 'Mango'}],
    'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': bundle + '.FlowTests',
                         'GENERATE_INFOPLIST_FILE': 'YES', 'TEST_TARGET_NAME': 'Mango'}}}
spec['schemes']['LibraryAuditQA'] = {
    'build': {'targets': {'Mango': 'all', 'FlowUITests': ['test']}},
    'test': {'targets': ['FlowUITests'], 'environmentVariables': {
        'QA_ORIENTATION': args.orientation, 'MANGO_QA_BUNDLE': bundle}}}
(work / 'project.yml').write_text(yaml.safe_dump(spec, sort_keys=False))
subprocess.run(['xcodegen', 'generate', '--spec', str(work / 'project.yml')], check=True)
derived = '/tmp/Mango-LibraryUIAuditDerivedData-' + args.udid
command = ['xcodebuild', '-project', str(work / 'Mango.xcodeproj'), '-scheme', 'LibraryAuditQA',
           '-destination', 'platform=iOS Simulator,id=' + args.udid, '-parallel-testing-enabled', 'NO',
           '-collect-test-diagnostics', 'never', '-derivedDataPath', derived]
with (work / 'build.log').open('w') as log:
    subprocess.run(command + ['build-for-testing'], stdout=log, stderr=subprocess.STDOUT, check=True)
subprocess.run(['xcrun', 'simctl', 'install', args.udid, derived + '/Build/Products/Debug-iphonesimulator/Mango.app'], check=True)
container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', args.udid, bundle, 'data'], text=True).strip())
documents = container / 'Documents'
documents.mkdir(exist_ok=True)
marker = documents / '.library-ui-audit'
if not marker.exists():
    if any(documents.iterdir()):
        raise SystemExit('Refusing to overwrite pre-existing QA Documents')
    shutil.copytree(fixtures, documents / 'Demo')
    marker.write_text('Invented books from Mango scripts/make-demo-library.py\n')
tests = command + ['test-without-building', '-resultBundlePath', str(args.result)]
for method in args.only:
    tests += ['-only-testing:FlowUITests/FlowTests/' + method]
print('Results:', args.result, flush=True)
with args.result.with_suffix('.log').open('w') as log:
    result = subprocess.run(tests, stdout=log, stderr=subprocess.STDOUT)
raise SystemExit(result.returncode)
