# windows_update.py
# Asks Windows Update what it offers a Windows 11 device, the way Windows' own update client asks, and gets the files it lists. This is
# how the builds of the Windows Insider channels are fetched from Microsoft without enrolling anything: Windows Update gives a channel's
# newest build to a request that describes a device in that channel. Nothing is registered or signed in, and the VM the build goes into
# keeps Windows' default configuration.
#
# The requests are those of Microsoft's Windows Update protocol (MS-WUSP), as the Microsoft Store also makes them (see
# Install-Store-Apps.ps1 in ThioJoe/Windows-Sandbox-Tools): GetCookie, then SyncUpdates, whose answer has the update offered with its
# files and their hashes, then GetExtendedUpdateInfo2 for the files' download links. An Insider build's update lists every file of the
# build, in every language and edition (about 100 GB). A device that's already in the channel only installs a few of them (packages()):
# the cumulative update, the checkpoint cumulative update it builds on, the enablement package that gives the build the channel's build
# number, and the build's .NET Framework update. A device on a released build can't install those: the channels' cumulative updates
# are built on the channels' own baseline (ge_release_flt 26100.6, not the released builds' 26100.1), so a released build becomes an
# Insider build by an in-place upgrade, as Microsoft's docs say of switching channels.
#
#   python windows_update.py offer --channel Experimental --os-build 26300.9711       # the update offered (build, KB, ID), as JSON
#     --json-out offer.json                     also writes it to this file
#   python windows_update.py links --channel Experimental --os-build 26300.9711       # its packages, with their download links
#   python windows_update.py download --channel Experimental --os-build 26300.9711 --out <folder>   # downloads the packages
#   python windows_update.py image --channel Experimental --out <folder>              # and a new installation's files and apps (Windows only)
#
# The download links last from 10 minutes (small files) to several hours (the cumulative update), so they're asked for right before
# the downloads. They're plain HTTP, as Windows Update's are; each file is checked against the SHA-256 in the update's metadata, which
# comes over HTTPS from the update service.

import argparse
import base64
import hashlib
import html
import json
import os
import re
import ssl
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

SERVICE_URL = 'https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx'
USER_AGENT = 'Windows-Feature-ID-Scanner'

# The update service's certificate chains to "Microsoft Root Certificate Authority 2011", which Windows trusts and Linux doesn't. On
# Linux it's downloaded from Microsoft's PKI site and checked against its SHA-256 fingerprint before it's trusted.
ROOT_CA_URL = 'https://www.microsoft.com/pki/certs/MicRooCerAut2011_2011_03_22.crt'
ROOT_CA_SHA256 = '847df6a78497943f27fc72eb93f9a637320a02b561d0a91b09e87a7807ed7c61'

# The Insider channels, by their names in the release notes index (as check-windows-builds.py lists them): the branch name a device in
# the channel reports (FlightingBranchName; Microsoft's business docs call Experimental "formerly the Dev Channel"), the branch of the
# Windows core the channel's builds are on, and a build on that core for a request to describe when there's no device to describe.
# 26H1 and Future Platforms are cores a device picks within Beta or Experimental; a device described as on that core is offered its
# newest build.
CHANNELS = {
    'Beta': ('Beta', 'ge_release', '26100.1'),
    'Experimental': ('Dev', 'ge_release', '26100.1'),
    'Beta (26H1)': ('Beta', 'br_release', '28000.1'),
    'Experimental (26H1)': ('Dev', 'br_release', '28000.1'),
    'Experimental (Future Platforms)': ('Dev', 'rs_prerelease', '29500.1000'),
    'Release Preview 24H2/25H2/26H2': ('ReleasePreview', 'ge_release', '26100.1'),
    'Release Preview 26H1': ('ReleasePreview', 'br_release', '28000.1'),
}

EDITION_SKUS = {'Enterprise': 4, 'Professional': 48, 'Education': 121, 'Core': 101}  # OSSkuId (PRODUCT_* in GetProductInfo)

NS = {'w': 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService'}


def log(msg):
    print('[wu] ' + msg, file=sys.stderr)


def ssl_context():
    ctx = ssl.create_default_context()
    if sys.platform != 'win32':
        req = urllib.request.Request(ROOT_CA_URL, headers={'User-Agent': USER_AGENT})
        with urllib.request.urlopen(req, timeout=60) as r:
            der = r.read()
        if hashlib.sha256(der).hexdigest() != ROOT_CA_SHA256:
            raise RuntimeError("Microsoft's root certificate from %s doesn't have the expected fingerprint" % ROOT_CA_URL)
        ctx.load_verify_locations(cadata=der)
    return ctx


def timestamp(minutes=0):
    return (datetime.now(timezone.utc) + timedelta(minutes=minutes)).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'


def device_attributes(channel, os_build, edition='Enterprise', architecture='AMD64'):
    """The attributes a Windows 11 device in the channel (None: not in any) sends with its requests, for a device at os_build."""
    branch_name, branch, _ = CHANNELS[channel] if channel else ('', None, None)
    version = '10.0.' + os_build
    attributes = {
        'App': 'WU_OS', 'AppVer': version, 'AttrDataVer': '331', 'BranchReadinessLevel': 'CB', 'CurrentBranch': branch or 'ge_release',
        'DefaultUserRegion': '244', 'DeviceFamily': 'Windows.Desktop', 'DeviceInfoGatherSuccessful': '1',
        'FlightRing': 'External' if channel else 'Retail', 'FlightingBranchName': branch_name, 'Free': 'gt64',
        'InstallationType': 'Client', 'InstallLanguage': 'en-US', 'IsFlightingEnabled': '1' if channel else '0',
        'OEMModel': 'Virtual Machine', 'OEMName_Uncleaned': 'Microsoft Corporation', 'OSArchitecture': architecture,
        'OSSkuId': str(EDITION_SKUS[edition]), 'OSUILocale': 'en-US', 'OSVersion': version, 'ProcessorManufacturer': 'GenuineIntel',
        'SecureBootCapable': '1', 'TelemetryLevel': '3', 'TPMVersion': '2', 'UpdateManagementGroup': '2', 'WuClientVer': version}
    return 'E:' + '&'.join('%s=%s' % kv for kv in attributes.items())


class WindowsUpdate:
    def __init__(self, timeout=180):
        self.timeout = timeout
        self.ctx = ssl_context()
        self.cookie = None

    def _post(self, url, action, body):
        header = (
            '<s:Header>'
            f'<a:Action s:mustUnderstand="1">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/{action}</a:Action>'
            f'<a:MessageID>urn:uuid:{uuid.uuid4()}</a:MessageID><a:To s:mustUnderstand="1">{url}</a:To>'
            '<o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">'
            '<Timestamp xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">'
            f'<Created>{timestamp()}</Created><Expires>{timestamp(5)}</Expires></Timestamp>'
            # No account: the ticket is empty, as the Store's requests for free apps have it
            '<wuws:WindowsUpdateTicketsToken wsu:id="ClientMSA" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" '
            'xmlns:wuws="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization">'
            '<TicketType Name="MSA" Version="1.0" Policy="MBI_SSL"><user/></TicketType></wuws:WindowsUpdateTicketsToken>'
            '</o:Security></s:Header>')
        envelope = f'<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing" xmlns:s="http://www.w3.org/2003/05/soap-envelope">{header}<s:Body>{body}</s:Body></s:Envelope>'
        for attempt in range(4):
            req = urllib.request.Request(url, data=envelope.encode('utf-8'), method='POST',
                                         headers={'Content-Type': 'application/soap+xml; charset=utf-8', 'User-Agent': USER_AGENT})
            try:
                with urllib.request.urlopen(req, context=self.ctx, timeout=self.timeout) as r:
                    return r.read().decode('utf-8')
            except urllib.error.HTTPError as e:
                fault = re.search(r'<(?:\w+:)?(?:Text|faultstring|ErrorCode)[^>]*>(.*?)</', e.read().decode('utf-8', 'replace'), re.S)
                problem = 'HTTP %d%s' % (e.code, ': ' + fault.group(1).strip() if fault else '')
                if e.code < 500:
                    raise RuntimeError(f'{action}: {problem}')
            except (urllib.error.URLError, OSError) as e:
                problem = str(e)
            if attempt == 3:
                raise RuntimeError(f'{action}: {problem}')
            log(f'{action} failed ({problem}); trying again')
            time.sleep(10 * (attempt + 1))

    def get_cookie(self):
        text = self._post(SERVICE_URL, 'GetCookie', f'<GetCookie xmlns="{NS["w"]}" />')
        self.cookie = re.search(r'<EncryptedData>(.*?)</EncryptedData>', text, re.S).group(1)

    def sync_updates(self, device, products, installed):
        """The updates SyncUpdates returns: {ID: {'id', 'leaf', 'type', 'updateId', 'revision', 'core', 'extended', 'title'}}."""
        if not self.cookie:
            self.get_cookie()
        caller = 'E:Interactive=1&IsSeeker=1&Acquisition=1&SheddingAware=1&Id=MoUpdateOrchestrator'  # A "Check for updates" click
        body = (
            f'<SyncUpdates xmlns="{NS["w"]}">'
            f'<cookie><Expiration>{timestamp(60 * 24 * 365)}</Expiration><EncryptedData>{self.cookie}</EncryptedData></cookie>'
            '<parameters><ExpressQuery>false</ExpressQuery>'
            f'<InstalledNonLeafUpdateIDs>{"".join("<int>%d</int>" % i for i in installed)}</InstalledNonLeafUpdateIDs>'
            '<OtherCachedUpdateIDs/><SkipSoftwareSync>false</SkipSoftwareSync><NeedTwoGroupOutOfScopeUpdates>true</NeedTwoGroupOutOfScopeUpdates>'
            '<AlsoPerformRegularSync>true</AlsoPerformRegularSync><ComputerSpec/>'
            '<ExtendedUpdateInfoParameters><XmlUpdateFragmentTypes><XmlUpdateFragmentType>Extended</XmlUpdateFragmentType>'
            '<XmlUpdateFragmentType>LocalizedProperties</XmlUpdateFragmentType></XmlUpdateFragmentTypes>'
            '<Locales><string>en-US</string><string>en</string></Locales></ExtendedUpdateInfoParameters>'
            '<ClientPreferredLanguages><string>en-US</string></ClientPreferredLanguages>'
            '<ProductsParameters><SyncCurrentVersionOnly>false</SyncCurrentVersionOnly>'
            f'<DeviceAttributes>{html.escape(device)}</DeviceAttributes><CallerAttributes>{html.escape(caller)}</CallerAttributes>'
            f'<Products>{html.escape(products)}</Products></ProductsParameters></parameters></SyncUpdates>')
        result = ET.fromstring(self._post(SERVICE_URL, 'SyncUpdates', body)).find('.//w:SyncUpdatesResult', NS)
        if result is None:
            raise RuntimeError('SyncUpdates: no result in the response')
        updates = {}
        for info in result.findall('w:NewUpdates/w:UpdateInfo', NS):
            core = info.findtext('w:Xml', '', NS)
            ident = re.search(r'<UpdateIdentity UpdateID="([^"]+)" RevisionNumber="(\d+)"', core)
            kind = re.search(r'<Properties UpdateType="(\w+)"', core)
            updates[info.findtext('w:ID', '', NS)] = {
                'id': info.findtext('w:ID', '', NS), 'leaf': info.findtext('w:IsLeaf', '', NS) == 'true', 'type': kind and kind.group(1),
                'updateId': ident and ident.group(1), 'revision': ident and int(ident.group(2)), 'core': core}
        for update in result.findall('w:ExtendedUpdateInfo/w:Updates/w:Update', NS):
            entry = updates.setdefault(update.findtext('w:ID', '', NS), {'id': update.findtext('w:ID', '', NS)})
            fragment = update.findtext('w:Xml', '', NS)
            title = re.search(r'<Title>(.*?)</Title>', fragment, re.S)
            if title:
                entry['title'] = html.unescape(title.group(1))
            elif '<ExtendedProperties' in fragment:
                entry['extended'] = fragment
        return updates

    def file_urls(self, device, update_id, revision):
        """{SHA-1 (hex): download link} for every file of an update."""
        url = SERVICE_URL + '/secured'
        body = (f'<GetExtendedUpdateInfo2 xmlns="{NS["w"]}"><updateIDs><UpdateIdentity><UpdateID>{update_id}</UpdateID>'
                f'<RevisionNumber>{revision}</RevisionNumber></UpdateIdentity></updateIDs>'
                '<infoTypes><XmlUpdateFragmentType>FileUrl</XmlUpdateFragmentType></infoTypes>'
                f'<deviceAttributes>{html.escape(device)}</deviceAttributes></GetExtendedUpdateInfo2>')
        text = self._post(url, 'GetExtendedUpdateInfo2', body)
        return {base64.b64decode(digest).hex(): html.unescape(link)
                for digest, link in re.findall(r'<FileLocation><FileDigest>(.*?)</FileDigest><Url>(.*?)</Url>', text, re.S)}


def update_files(extended):
    """[{'name', 'size', 'sha1', 'sha256'}] from an update's extended metadata. A name can be there more than once."""
    files = []
    for attributes, inner in re.findall(r'<File ([^>]*?)(?:/>|>(.*?)</File>)', extended, re.S):
        a = dict(re.findall(r'(\w+)="([^"]*)"', attributes))
        sha256 = re.search(r'<AdditionalDigest Algorithm="SHA256">(.*?)</AdditionalDigest>', inner or '')
        files.append({'name': a['FileName'], 'size': int(a.get('Size', 0)), 'sha1': base64.b64decode(a['Digest']).hex(),
                      'sha256': base64.b64decode(sha256.group(1)).hex() if sha256 else None})
    return files


def offer(client, channel, os_build, edition='Enterprise', architecture='AMD64'):
    """What Windows Update offers a device at os_build in the channel (None: not in any channel): the newest Windows update among
    the updates it returns, with its build, KB and files."""
    branch = CHANNELS[channel][1] if channel else 'ge_release'
    device = device_attributes(channel, os_build, edition, architecture)
    products = 'PN=Client.OS.rs2.%s&Branch=%s&PrimaryOSProduct=1&Repairable=1&V=10.0.%s&ReofferUpdate=1' % (architecture.lower(), branch, os_build)
    # A client reports which of the categories and detectoids it's given apply, and asks again. Windows' updates only need the
    # categories (the feature update's prerequisite is the Upgrades category). Detectoids aren't reported: among them are "osring"
    # detectoids that test HKLM\Software\Microsoft\WindowsSelfHost\Applicability\Ring, and reporting them would describe a device in
    # Microsoft's internal rings.
    installed, offers = [1, 2, 3, 11, 19], []
    for _ in range(3):
        updates = client.sync_updates(device, products, installed)
        for u in updates.values():
            release = re.search(r'<ProductReleaseInstalled Name="Client\.OS\.RS2\.\w+" Version="10\.0\.(\d+\.\d+)"', u.get('core') or '', re.I)
            if u.get('leaf') and release and u.get('extended'):
                kb = re.search(r'<KBArticleID>(\d+)</KBArticleID>', u['extended'])
                offers.append({'title': u.get('title'), 'build': release.group(1), 'updateId': u['updateId'], 'revision': u['revision'],
                               'kb': 'KB' + kb.group(1) if kb else None, 'files': update_files(u['extended'])})
        more = [int(u['id']) for u in updates.values() if u.get('type') == 'Category' and int(u['id']) not in installed]
        if offers or not more:
            break
        installed += more
    if not offers:
        raise RuntimeError(f'Windows Update offers no Windows update to a device at {os_build} in the {channel or "retail"} channel')
    best = max(offers, key=lambda o: tuple(int(x) for x in o['build'].split('.')))
    return dict(best, channel=channel, osBuild=os_build, device=device)


def cab_names(data):
    """The names of the files in a cabinet (Microsoft's .cab format, MS-CAB), from its file entries. Nothing is decompressed."""
    if data[:4] != b'MSCF':
        raise ValueError('not a cabinet file')
    first, = struct.unpack_from('<I', data, 16)  # coffFiles
    count, = struct.unpack_from('<H', data, 28)  # cFiles
    names, pos = [], first
    for _ in range(count):
        attributes, = struct.unpack_from('<H', data, pos + 14)
        end = data.index(b'\0', pos + 16)
        names.append(data[pos + 16:end].decode('utf-8' if attributes & 0x80 else 'latin-1'))  # 0x80: _A_NAME_IS_UTF
        pos = end + 1
    return names


def metadata_cab(client, update):
    """The update's AggregatedMetadata.cab (a few MB): the component databases that describe its packages and editions."""
    name = update['updateId'].lower() + '.aggregatedmetadata.cab'
    meta = next((f for f in update['files'] if f['name'].lower() == name), None)
    if not meta:
        raise RuntimeError(f"the update lists no {name}")
    data = None
    for attempt in range(4):
        try:
            req = urllib.request.Request(with_links(client, update, [meta])[0]['url'], headers={'User-Agent': USER_AGENT})
            with urllib.request.urlopen(req, timeout=120) as r:
                data = r.read()
            if hashlib.sha256(data).hexdigest() == meta['sha256']:
                break
            problem = "it doesn't match its SHA-256"
        except (urllib.error.URLError, OSError) as e:
            problem = str(e)
        data = None
        log(f"downloading {meta['name']} failed ({problem}); trying again")
        time.sleep(10 * (attempt + 1))
    if data is None:
        raise RuntimeError(f"couldn't download {meta['name']}")
    return data


def package_roles(client, update):
    """{KB: role} of the update's packages, from the names of the component databases in its AggregatedMetadata.cab, which say what
    each package is: EKBUpdateCompDB_<KB> (an enablement package), outer.AggregatedMetadata_<KB> (the cumulative update, or a
    checkpoint cumulative update it builds on), SafeOSDUCompDB_<KB> and SetupDUCompDB_<KB> (the Safe OS and Setup dynamic updates).
    DotNetServicingCompDB is the .NET Framework update, under the key 'dotnet'."""
    roles = {}
    for n in cab_names(metadata_cab(client, update)):
        m = re.match(r'(?i)(EKBUpdateCompDB|outer\.AggregatedMetadata|SafeOSDUCompDB|SetupDUCompDB)_(KB\d+)\.', n)
        if m:
            kind = m.group(1).lower()
            roles[m.group(2).upper()] = {'ekbupdatecompdb': 'enablement', 'safeosducompdb': 'safeos', 'setupducompdb': 'setup'}.get(
                kind, 'cumulative' if m.group(2).upper() == update['kb'] else 'checkpoint')
        elif n.lower().startswith('dotnetservicingcompdb'):
            roles['dotnet'] = 'dotnet'
    return roles


def packages(client, update, architecture='x64'):
    """The update's packages that a device already on the channel's baseline installs to get its build, in the order they're installed: the
    checkpoint cumulative updates (DISM installs the ones a device still needs when they're in the cumulative update's folder), the
    cumulative update, the enablement package that gives the build its number, and the .NET Framework update. Each has its role
    (package_roles) and KB. Left out: the Safe OS dynamic update (WinRE's) and the Setup dynamic update (for Windows Setup), and the
    images and packages for new installations and other Windows cores, which are most of the update."""
    roles = package_roles(client, update)
    if update['kb'] not in roles:
        raise RuntimeError(f"the update's metadata doesn't have its cumulative update {update['kb']}: it isn't one a device on the same "
                           f"Windows core installs ({', '.join(f'{kb} {role}' for kb, role in sorted(roles.items())) or 'nothing'})")
    wanted = {'checkpoint': 'msu', 'cumulative': 'msu', 'enablement': 'cab'}
    picked = []
    for kb, role in sorted(roles.items()):
        if role in wanted:
            pattern = r'(?i)^windows\d+\.\d+-%s-%s\.%s$' % (kb, architecture, wanted[role])
        elif role == 'dotnet':
            pattern = r'(?i)^windows\d+\.\d+-kb\d+-%s-ndp\d+\.cab$' % architecture
        else:
            continue
        found = {f['sha1']: f for f in update['files'] if re.match(pattern, f['name'])}
        if len(found) != 1:
            raise RuntimeError(f"the update has {len(found)} files for its {role} package ({kb})")
        f = next(iter(found.values()))
        picked.append(dict(f, role=role, kb=kb if kb != 'dotnet' else re.search(r'(?i)-(kb\d+)-', f['name']).group(1).upper()))
    order = ['checkpoint', 'cumulative', 'enablement', 'dotnet']
    return sorted(picked, key=lambda p: (order.index(p['role']), p['name'].lower()))


def expand_member(cab, member, folder):
    """Extracts one file from a cabinet with Windows' own expand.exe (cabinet.dll), and returns its path. Windows only: the metadata's
    cabinets aren't in a compression Python's standard library reads."""
    os.makedirs(folder, exist_ok=True)
    r = subprocess.run(['expand.exe', '-F:' + member, cab, folder], capture_output=True, text=True)
    found = [n for n in os.listdir(folder) if n.lower() == member.lower()]
    if r.returncode or not found:
        raise RuntimeError(f"expand.exe couldn't extract {member} from {cab} ({r.returncode}): {(r.stdout + r.stderr).strip()[-300:]}")
    return os.path.join(folder, found[0])


def image_files(client, update, folder, edition='professional', language='en-us'):
    """What a new installation of the update's build in one edition and language is made of, from that edition's component database
    (DesktopTargetCompDB_<edition>_<language> in AggregatedMetadata.cab): the edition's image (<edition>_<language>.esd, whose last
    image is the installation's), the package ESDs and WIMs that hold the files the image refers to but doesn't contain, and the
    packages that come as cabs (the Features on Demand an installation has, and the like), whose files the image refers to as well.
    Each payload is matched to the update's files by the SHA-256 the database gives it. The edition's feature also names the apps an
    installation of it has, which the update has as separate packages (app_files)."""
    os.makedirs(folder, exist_ok=True)
    meta = os.path.join(folder, 'AggregatedMetadata.cab')
    with open(meta, 'wb') as f:
        f.write(metadata_cab(client, update))
    root = compdb(meta, f'DesktopTargetCompDB_{edition}_{language}.xml.cab', folder)
    by_sha256 = {f['sha256']: f for f in update['files'] if f['sha256']}
    ns = {'c': 'http://schemas.microsoft.com/embedded/2004/10/ImageUpdate'}
    files, missing = {}, []
    for item in root.iterfind('.//c:Packages/c:Package/c:Payload/c:PayloadItem', ns):
        f = by_sha256.get(base64.b64decode(item.get('PayloadHash')).hex())
        if f:
            files[f['sha1']] = f
        else:
            missing.append(item.get('Path'))
    if missing:
        raise RuntimeError(f"the update has no file for {len(missing)} of the {edition} {language} payloads: {', '.join(missing[:5])}")
    files = sorted(files.values(), key=lambda f: f['name'].lower())
    image = [f for f in files if f['name'].lower() == f'{edition}_{language}.esd']
    if len(image) != 1:
        raise RuntimeError(f'the {edition} {language} payloads have {len(image)} files named {edition}_{language}.esd')
    apps = [f.get('FeatureID') for f in root.iterfind('c:Features/c:Feature/c:Dependencies/c:Feature', ns) if f.get('Group') == 'PreinstalledApps']
    return {'edition': edition, 'language': language, 'image': image[0]['name'], 'metadata': meta,
            'references': [f['name'] for f in files if re.search(r'(?i)\.(esd|wim)$', f['name'])],
            'cabs': [f['name'] for f in files if f['name'].lower().endswith('.cab')], 'files': files, 'apps': apps}


def compdb(meta, name, folder):
    """A component database from the AggregatedMetadata.cab at meta, by its name there (case doesn't matter), parsed. It's a cabinet
    inside the metadata cabinet; the file in it has the same name."""
    with open(meta, 'rb') as f:
        member = next((n for n in cab_names(f.read()) if n.lower() == name.lower()), None)
    if not member:
        raise RuntimeError(f'the update has no {name}')
    inner = expand_member(meta, member, os.path.join(folder, 'compdb-cab'))
    return ET.parse(expand_member(inner, member, os.path.join(folder, 'compdb'))).getroot()


def app_files(update, meta, folder, wanted):
    """The apps a new installation of the build has, which the update has as separate packages: wanted is the FeatureIDs of the apps
    the edition has (image_files), and the app database (DesktopTargetCompDB_App_Neutral in AggregatedMetadata.cab) has a feature for
    each app in the PreinstalledApps group, which has the file to provision (a bundle, whose packages are separate files that go next
    to it, or the app's own package), the frameworks it requires (features of their own) and its license. Payloads the update has no
    file for (other architectures' packages) are left out. Returns {'apps': [{'id', 'type', 'main', 'dependencies', 'license'}],
    'frameworks': {id: [files]}, 'files': [file dicts]}."""
    ns = {'c': 'http://schemas.microsoft.com/embedded/2004/10/ImageUpdate'}
    root = compdb(meta, 'DesktopTargetCompDB_App_Neutral.xml.cab', folder)
    by_sha256 = {f['sha256']: f for f in update['files'] if f['sha256']}
    payloads = {}  # Package ID: its files in the update
    for package in root.iterfind('c:Packages/c:Package', ns):
        found = [by_sha256.get(base64.b64decode(i.get('PayloadHash')).hex()) for i in package.iterfind('c:Payload/c:PayloadItem', ns)]
        payloads[package.get('ID')] = [f for f in found if f]
    features = {f.get('FeatureID'): f for f in root.iterfind('c:Features/c:Feature', ns) if f.get('Group') == 'PreinstalledApps'}
    missing = [i for i in wanted if i not in features]
    if missing:
        raise RuntimeError(f"the app database has no feature for {', '.join(missing)}")
    apps, frameworks, files = [], {}, {}

    def own_files(feature_id):
        own = [f for p in features[feature_id].iterfind('c:Packages/c:Package', ns) for f in payloads.get(p.get('ID'), [])]
        for f in own:
            files[f['sha1']] = f
        return own

    for feature_id in wanted:
        feature = features[feature_id]
        own = own_files(feature_id)
        if not own:
            continue  # Nothing in the update for this architecture
        bundles = [f for f in own if re.search(r'(?i)\.(msix|appx)bundle$', f['name'])]
        packages = [f for f in own if not re.search(r'(?i)[._]split\.|language-|scale-|\.(msix|appx)bundle$', f['name'])]
        main = bundles or packages
        if len(main) != 1:
            raise RuntimeError(f"the app {feature_id} has {len(main)} files that could be its package: {[f['name'] for f in main]}")
        dependencies = [d.get('FeatureID') for d in feature.iterfind('c:Dependencies/c:Feature', ns)]
        for d in dependencies:
            if d not in features:
                raise RuntimeError(f'the app {feature_id} requires {d}, which the app database has no feature for')
            if d not in frameworks:
                frameworks[d] = sorted({f['name'] for f in own_files(d)})
        license = feature.find("c:CustomInformation/c:CustomInfo[@Key='licensedata']", ns)
        apps.append({'id': feature_id, 'type': feature.get('Type'), 'main': main[0]['name'], 'dependencies': dependencies,
                     'license': license.text.strip() if license is not None and license.text else None})
    return {'apps': apps, 'frameworks': frameworks, 'files': sorted(files.values(), key=lambda f: f['name'].lower())}


def with_links(client, update, files):
    """The files with their download links, asked for now (they expire)."""
    urls = client.file_urls(update['device'], update['updateId'], update['revision'])
    missing = [f['name'] for f in files if f['sha1'] not in urls]
    if missing:
        raise RuntimeError('Windows Update gave no download link for ' + ', '.join(missing))
    return [dict(f, url=urls[f['sha1']]) for f in files]


def download(client, update, files, folder):
    """Downloads the files into folder, each checked against its SHA-256. A file that's there already and matches is kept. Links are
    asked for again when a download fails, since they expire."""
    os.makedirs(folder, exist_ok=True)
    links = {}
    for f in sorted(files, key=lambda f: f['size']):  # Smallest first: their links expire soonest
        path = os.path.join(folder, f['name'])
        if os.path.exists(path) and os.path.getsize(path) == f['size'] and sha256_of(path) == f['sha256']:
            log(f"{f['name']}: already downloaded")
            continue
        for attempt in range(5):
            if attempt or link_expiry(links.get(f['sha1'])) < time.time() + 60:
                links = {g['sha1']: g['url'] for g in with_links(client, update, files)}
            url = links[f['sha1']]
            done = os.path.getsize(path) if os.path.exists(path) else 0
            if done >= f['size']:
                os.remove(path)
                done = 0
            log(f"downloading {f['name']} ({f['size']:,} bytes){' from byte %d' % done if done else ''}")
            req = urllib.request.Request(url, headers={'User-Agent': USER_AGENT, **({'Range': 'bytes=%d-' % done} if done else {})})
            try:
                with urllib.request.urlopen(req, timeout=120) as r, open(path, 'ab' if done and r.status == 206 else 'wb') as out:
                    while True:
                        chunk = r.read(1 << 20)
                        if not chunk:
                            break
                        out.write(chunk)
            except (urllib.error.URLError, OSError) as e:
                log(f"the download stopped ({e}); trying again")
                time.sleep(10)
                continue
            if os.path.getsize(path) == f['size'] and sha256_of(path) == f['sha256']:
                break
            log(f"{f['name']} doesn't match its SHA-256; downloading it again")
            os.remove(path)
        else:
            raise RuntimeError(f"couldn't download {f['name']}")


def link_expiry(url):
    """When a download link expires (its P1 parameter), or 0."""
    m = re.search(r'[?&]P1=(\d+)', url or '')
    return int(m.group(1)) if m else 0


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 22), b''):
            h.update(chunk)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description="Ask Windows Update what it offers a device in a Windows Insider channel, and get the files.")
    parser.add_argument('action', choices=['offer', 'links', 'download', 'image'],
                        help="image (Windows only): download a new installation's files and apps, and the packages that bring it to the build")
    parser.add_argument('--channel', required=True, help='An Insider channel, by its name in the release notes: ' + ', '.join(CHANNELS) + "; or 'retail'")
    parser.add_argument('--os-build', help="The build of the device asking, such as 26300.9711 (default: the start of the channel's Windows core)")
    parser.add_argument('--os-branch', help="The device's branch (from its BuildLabEx, such as ge_release): an error if the channel's builds are on another core")
    parser.add_argument('--edition', default='Enterprise', choices=sorted(EDITION_SKUS))
    parser.add_argument('--image-edition', default='professional', help='image: the edition of the installation image (its ESD is <edition>_<language>.esd)')
    parser.add_argument('--language', default='en-us', help='image: the installation\'s language')
    parser.add_argument('--expected-build', help='An error unless Windows Update offers this build')
    parser.add_argument('--out', help='download, image: the folder the files go in')
    parser.add_argument('--json-out', help='Also write the JSON to this file')
    args = parser.parse_args()

    channel = None if args.channel.lower() == 'retail' else args.channel
    if channel and channel not in CHANNELS:
        parser.error(f'unknown channel {channel!r}')
    if args.action in ('download', 'image') and not args.out:
        parser.error(f'{args.action} needs --out')
    if not args.os_build:
        if not channel:
            parser.error("the retail channel needs --os-build")
        args.os_build = CHANNELS[channel][2]
    if channel and args.os_branch and not args.os_branch.startswith(CHANNELS[channel][1]):  # ge_release_flt: the flights of ge_release
        log(f"The {channel} channel's builds are on another Windows core ({CHANNELS[channel][1]}) than a device on {args.os_branch}")
        return 2
    client = WindowsUpdate()
    update = offer(client, channel, args.os_build, args.edition)
    log(f"offered: {update['title']} (build {update['build']}, {update['kb'] or 'no KB'}, update {update['updateId']} revision {update['revision']}, {len(update['files'])} files)")
    if args.expected_build and update['build'] != args.expected_build:
        log(f"Windows Update offers build {update['build']}, not {args.expected_build}")
        return 3
    result = {k: update[k] for k in ('channel', 'osBuild', 'title', 'build', 'kb', 'updateId', 'revision')}
    result['fileCount'] = len(update['files'])
    if args.action in ('links', 'download', 'image'):
        picked = packages(client, update)
        for p in picked:
            log(f"  {p['role']}: {p['name']} ({p['size']:,} bytes)")
        if args.action == 'links':
            picked = with_links(client, update, picked)
        elif args.action == 'download':
            download(client, update, picked, args.out)
        else:
            image = image_files(client, update, args.out, args.image_edition.lower(), args.language.lower())
            log(f"installation image: {image['image']}, with {len(image['references']) - 1} ESDs and WIMs and {len(image['cabs'])} cabs "
                f"({sum(f['size'] for f in image['files']) / 1e9:.1f} GB)")
            apps = app_files(update, image['metadata'], args.out, image['apps'])
            log(f"apps: {len(apps['apps'])}, with {len(apps['frameworks'])} frameworks ({sum(f['size'] for f in apps['files']) / 1e9:.1f} GB)")
            download(client, update, image['files'] + apps['files'] + picked, args.out)
            result['image'] = {k: image[k] for k in ('edition', 'language', 'image', 'references', 'cabs')}
            result['apps'] = {k: apps[k] for k in ('apps', 'frameworks')}
            result['folder'] = os.path.abspath(args.out)
        result['packages'] = picked
    text = json.dumps(result, indent=1)
    if args.json_out:
        with open(args.json_out, 'w', encoding='utf-8', newline='\n') as f:
            f.write(text + '\n')
    print(text)
    return 0


if __name__ == '__main__':
    sys.exit(main())
