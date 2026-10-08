from pathlib import Path
import tempfile, shutil, os, subprocess
root = Path.cwd()
with tempfile.TemporaryDirectory() as temp:
    fixture = Path(temp)
    (fixture/'scripts').mkdir()
    (fixture/'Resources').mkdir()
    (fixture/'bin').mkdir()
    (fixture/'build').mkdir()
    shutil.copy2(root/'scripts/build-app.sh', fixture/'scripts/build-app.sh')
    shutil.copy2(root/'Info.plist', fixture/'Info.plist')
    (fixture/'build/AIUsageIsland').write_text('fixture executable')
    swift = fixture/'bin/swift'
    swift.write_text('#!/bin/sh\ncase "$*" in *--show-bin-path*) printf "%s\\n" "$FIXTURE_BUILD" ;; esac\n')
    swift.chmod(0o755)
    previous = fixture/'output/AIUsageIsland.app/sentinel'
    previous.parent.mkdir(parents=True)
    previous.write_text('previous usable artifact')
    env = dict(os.environ, PATH=str(fixture/'bin')+os.pathsep+os.environ['PATH'], FIXTURE_BUILD=str(fixture/'build'))
    result = subprocess.run(['bash',str(fixture/'scripts/build-app.sh'),str(fixture/'output')],env=env,capture_output=True,text=True,errors="replace")
    assert result.returncode != 0, 'Missing icon must fail'
    assert previous.exists(), 'Failed preflight must preserve previous usable artifact'
    # A present icon must not allow packaging without the SwiftPM resource bundle.
    (fixture/'Resources/AppIcon.icns').write_bytes(b'fixture icon')
    result = subprocess.run(['bash',str(fixture/'scripts/build-app.sh'),str(fixture/'output')],env=env,capture_output=True,text=True,errors="replace")
    assert result.returncode != 0 and previous.exists(), 'Missing bundle must preserve the old artifact'
    assert '缺少 SwiftPM 资源包' in result.stderr, 'Must reach the resource check: '+result.stderr
    formal_env = {key: value for key, value in env.items() if key not in ['SIGNING_IDENTITY', 'NOTARY_KEYCHAIN_PROFILE']}
    result = subprocess.run(['bash',str(fixture/'scripts/build-app.sh'),str(fixture/'output'),'--mode','release'],env=formal_env,capture_output=True,text=True,errors="replace")
    assert result.returncode != 0 and 'SIGNING_IDENTITY' in result.stderr and previous.exists()
    print('PASS: missing icon/bundle and missing formal credentials fail while preserving the previous artifact')
