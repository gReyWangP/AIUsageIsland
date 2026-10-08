from pathlib import Path
import base64, plistlib, subprocess, tempfile, zipfile, xml.etree.ElementTree as ET
root=Path.cwd()
ns={'s':'http://www.andymatuschak.org/xml-namespaces/sparkle'}
with tempfile.TemporaryDirectory() as temporary:
    fixture=Path(temporary)
    archive=fixture/'AIUsageIsland-1.19.15-build64-arm64.zip'
    info={'CFBundleShortVersionString':'1.19.15','CFBundleVersion':'64','CFBundleIdentifier':'com.deepseekisland.app','LSMinimumSystemVersion':'14.0','SUPublicEDKey':base64.b64encode(bytes(32)).decode()}
    with zipfile.ZipFile(archive,'w') as z: z.writestr('AIUsageIsland.app/Contents/Info.plist',plistlib.dumps(info))
    signer=fixture/'sign_update'
    signer.write_text('#!/bin/sh\ncase "$*" in *--verify*) exit 0 ;; esac\nprintf \'sparkle:edSignature="'+base64.b64encode(bytes(64)).decode()+'" length="'+str(archive.stat().st_size)+'"\\n\'\n')
    signer.chmod(0o755)
    keys=fixture/'generate_keys'
    keys.write_text('#!/bin/sh\nprintf \''+info['SUPublicEDKey']+'\\n\'\n'); keys.chmod(0o755)
    notes=fixture/'notes.md' ; notes.write_text('支持应用内更新 & 自动检查默认关闭')
    feed=fixture/'appcast.xml'
    command=['python3',str(root/'scripts/generate-update-feed.py'),'--archive',str(archive),'--appcast',str(feed),'--sign-tool',str(signer),'--notes',str(notes)]
    result=subprocess.run(command,capture_output=True,text=True)
    assert result.returncode==0,result.stderr
    item=ET.parse(feed).find('channel/item'); assert item is not None
    enclosure=item.find('enclosure')
    assert enclosure.attrib['length']==str(archive.stat().st_size)
    assert enclosure.attrib['{'+ns['s']+'}version']=='64'
    assert enclosure.attrib['url']=='https://github.com/gReyWangP/AIUsageIsland-releases/releases/download/v1.19.15/'+archive.name
    assert item.find('description').text==notes.read_text()
    assert item.find('description').attrib.get('{'+ns['s']+'}format')=='markdown', 'Release notes must use markdown format'
    old=feed.read_bytes()
    info['SUPublicEDKey']=base64.b64encode(bytes([1])*32).decode()
    with zipfile.ZipFile(archive,'w') as z: z.writestr('AIUsageIsland.app/Contents/Info.plist',plistlib.dumps(info))
    result=subprocess.run(command,capture_output=True,text=True)
    assert result.returncode!=0 and feed.read_bytes()==old, 'Mismatched packaged public key must be rejected'
    info['SUPublicEDKey']=base64.b64encode(bytes(32)).decode()
    with zipfile.ZipFile(archive,'w') as z: z.writestr('AIUsageIsland.app/Contents/Info.plist',plistlib.dumps(info))
    signer.write_text('#!/bin/sh\nexit 1\n')
    result=subprocess.run(command,capture_output=True,text=True)
    assert result.returncode!=0 and feed.read_bytes()==old, 'Signing failure must preserve feed'
    print('PASS: exact archive metadata, escaped notes, signed enclosure, failure preserves feed')
