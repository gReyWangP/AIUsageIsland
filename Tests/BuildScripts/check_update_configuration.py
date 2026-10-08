from pathlib import Path
import base64
import plistlib
info = plistlib.loads(Path('Info.plist').read_bytes())
assert info.get('SUEnableAutomaticChecks') is False, 'Automatic checks must explicitly default OFF'
assert info.get('SUAutomaticallyUpdate') is False, 'Silent downloads must explicitly default OFF'
assert info.get('SUFeedURL') == 'https://raw.githubusercontent.com/gReyWangP/AIUsageIsland-releases/main/appcast.xml'
assert len(base64.b64decode(info['SUPublicEDKey'], validate=True)) == 32
print('PASS: update defaults OFF, public HTTPS feed, valid Ed25519 public key')
