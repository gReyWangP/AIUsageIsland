#!/usr/bin/env python3
"""Create a stable GitHub appcast from the exact ZIP, signing via Sparkle's Keychain tool."""
import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
REPO = 'https://github.com/gReyWangP/AIUsageIsland-releases'
ET.register_namespace('sparkle', SPARKLE)

def generate(archive, appcast, sign_tool, notes):
    with zipfile.ZipFile(archive) as zipped:
        paths = [name for name in zipped.namelist() if re.fullmatch(r'[^/]+\.app/Contents/Info\.plist', name)]
        if len(paths) != 1:
            raise ValueError('Archive must contain exactly one top-level app')
        info = plistlib.loads(zipped.read(paths[0]))
    version = info['CFBundleShortVersionString']
    build = info['CFBundleVersion']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'[1-9]\d*', build):
        raise ValueError('Invalid version or build')
    if info['CFBundleIdentifier'] != 'com.deepseekisland.app':
        raise ValueError('Wrong app identity')
    if len(base64.b64decode(info['SUPublicEDKey'], validate=True)) != 32:
        raise ValueError('Invalid public key')
    key_tool = sign_tool.with_name('generate_keys')
    key_lookup = subprocess.run([str(key_tool), '--account', 'AIUsageIsland', '-p'], check=True, capture_output=True, text=True)
    if key_lookup.stdout.strip() != info['SUPublicEDKey']:
        raise ValueError('Packaged public key does not match the signing Keychain account')
    expected_name = f'AIUsageIsland-{version}-build{build}-arm64.zip'
    if archive.name != expected_name:
        raise ValueError(f'Archive name must be {expected_name}')
    signed = subprocess.run([str(sign_tool), '--account', 'AIUsageIsland', str(archive)], check=True, capture_output=True, text=True)
    attributes = re.fullmatch(r'\s*sparkle:edSignature="([A-Za-z0-9+/=]+)" length="(\d+)"\s*', signed.stdout)
    if not attributes or int(attributes[2]) != archive.stat().st_size:
        raise ValueError('Signer metadata does not match archive length')
    signature = attributes[1]
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('Invalid signature size')
    subprocess.run([str(sign_tool), '--account', 'AIUsageIsland', '--verify', str(archive), signature], check=True, capture_output=True)
    if appcast.exists():
        tree = ET.parse(appcast)
        channel = tree.find('channel')
        if channel is None: raise ValueError('Invalid existing appcast')
    else:
        tree = ET.ElementTree(ET.Element('rss', {'version': '2.0'}))
        channel = ET.SubElement(tree.getroot(), 'channel')
        ET.SubElement(channel, 'title').text = 'AI Usage Island'
        ET.SubElement(channel, 'link').text = REPO
        ET.SubElement(channel, 'description').text = 'AI Usage Island updates'
    for item in list(channel.findall('item')):
        enclosure = item.find('enclosure')
        if enclosure is not None and enclosure.get(f'{{{SPARKLE}}}version') == build:
            channel.remove(item)
    item = ET.Element('item')
    ET.SubElement(item, 'title').text = f'AI Usage Island {version}'
    ET.SubElement(item, 'pubDate').text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, 'description', {f'{{{SPARKLE}}}format': 'markdown'}).text = notes.read_text()
    ET.SubElement(item, f'{{{SPARKLE}}}minimumSystemVersion').text = info['LSMinimumSystemVersion']
    ET.SubElement(item, 'enclosure', {
        'url': f'{REPO}/releases/download/v{version}/{archive.name}',
        'length': attributes[2], 'type': 'application/octet-stream',
        f'{{{SPARKLE}}}version': build,
        f'{{{SPARKLE}}}shortVersionString': version,
        f'{{{SPARKLE}}}edSignature': signature,
    })
    channel.insert(3, item)
    ET.indent(tree, space='  ')
    appcast.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=appcast.parent, delete=False) as output:
            temporary = Path(output.name)
            tree.write(output, encoding='utf-8', xml_declaration=True)
        os.replace(temporary, appcast)
    finally:
        if temporary and temporary.exists(): temporary.unlink()
    print(f'Generated {appcast}: {version} ({build}), {archive.stat().st_size} bytes')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ('archive', 'appcast', 'sign-tool', 'notes'):
        parser.add_argument('--'+option, type=Path, required=True)
    args = parser.parse_args()
    generate(args.archive, args.appcast, args.sign_tool, args.notes)
