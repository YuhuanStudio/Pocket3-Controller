#!/usr/bin/env python3
"""Check shared design sources, translated UI strings and product identity."""
import hashlib,json,pathlib,plistlib,re
from product_metadata import metadata
root=pathlib.Path(__file__).resolve().parents[1]
provenance=json.loads((root/'ThirdParty/YunDesign/PROVENANCE.json').read_text())
for item in provenance['files']:
 actual=hashlib.sha256((root/item['target']).read_bytes()).hexdigest()
 assert actual==item['sha256'],f"Shared design file diverged: {item['target']}"
pattern=re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')
tables={}
for lang in ['en','zh-Hant','zh-Hans']:
 text=(root/f'Sources/Pocket3BridgeApp/Resources/{lang}.lproj/Localizable.strings').read_text()
 entries=[(json.loads('"'+a+'"'),json.loads('"'+b+'"')) for a,b in pattern.findall(text)]
 assert len(entries)==len(dict(entries)),f'Duplicate {lang} translation keys'
 tables[lang]=dict(entries)
keys=set()
# Error messages choose a key at runtime; loc(key.rawValue) is invisible to the
# literal-call scanner. Require every enum case to use a literal English key.
error_source=(root/'Sources/Pocket3BridgeApp/AppErrorPresentation.swift').read_text()
error_enum=re.search(r'enum AppErrorMessageKey\s*:\s*String,\s*CaseIterable\s*\{(.*?)\n\}',error_source,re.S)
assert error_enum,'Missing centralized error message key enum'
error_cases=re.findall(r'^\s*case\s+\w+\s*=\s*"((?:[^"\\]|\\.)*)"\s*$',error_enum.group(1),re.M)
assert error_cases and len(error_cases)==len(re.findall(r'^\s*case\b',error_enum.group(1),re.M)), 'Every error case must declare a literal English translation key'
error_keys={json.loads('"'+value+'"') for value in error_cases}
assert len(error_keys)==len(error_cases),'Duplicate centralized error message keys'
keys.update(error_keys)
activity_source=(root/'Sources/Pocket3BridgeApp/AppActivityPresentation.swift').read_text()
activity_enum=re.search(r'enum AppActivityMessageKey\s*:\s*String,\s*CaseIterable\s*\{(.*?)\n\}',activity_source,re.S)
assert activity_enum,'Missing centralized activity message key enum'
activity_cases=re.findall(r'^\s*case\s+\w+\s*=\s*"((?:[^"\\]|\\.)*)"\s*$',activity_enum.group(1),re.M)
assert activity_cases and len(activity_cases)==len(re.findall(r'^\s*case\b',activity_enum.group(1),re.M)), 'Every activity case must declare a literal English translation key'
activity_keys={json.loads('"'+value+'"') for value in activity_cases}
assert len(activity_keys)==len(activity_cases),'Duplicate centralized activity message keys'
keys.update(activity_keys)
for path in (root/'Sources/Pocket3BridgeApp').glob('*.swift'):
 text=path.read_text()
 assert 'Pocket 3 Bridge' not in text,f'Old visible product name in {path}'
 if path.name!='AppErrorPresentation.swift':
  assert not re.search(r'\b(?:message|audioMessage|issue|lastError|bridgeConnectionError)\s*=\s*error\.localizedDescription',text),f'Raw exception assigned to user-facing text in {path}'
 keys.update(json.loads('"'+m+'"') for m in re.findall(r'(?:loc|localize|caption|heading|setting|shortcut|permissionCard)\("((?:[^"\\]|\\.)*)"',text))
missing={lang:sorted(keys-table.keys()) for lang,table in tables.items()}
assert not any(missing.values()),missing
info=plistlib.loads((root/'Resources/Info.plist').read_bytes())
product_metadata=metadata(info)
assert info['CFBundleIconFile']=='Pocket3MCP.icns', 'Keep the existing icon resource identity'
product_source=(root/'Sources/Pocket3Core/ProductIdentity.swift').read_text()
def product_constant(name):
 match=re.search(r'\bstatic\s+let\s+'+re.escape(name)+r'\s*=\s*"([^"\\]*)"',product_source)
 assert match,f'Missing literal Pocket3Product.{name}'
 return match.group(1)
assert product_constant('displayName')==product_metadata['displayName'], 'Core and Info display names differ'
assert product_constant('version')==product_metadata['version'], 'Core and Info versions differ'
assert product_constant('prereleaseLabel')==f"{product_metadata['releaseChannel']} {product_metadata['prereleaseNumber']}", 'Core and Info Beta labels differ'
assert re.search(r'\bstatic\s+let\s+displayVersion\s*=\s*version\s*\+\s*" "\s*\+\s*prereleaseLabel',product_source), 'Review the composed Core display version'
semantic_suffix=product_metadata['semanticVersion'][len(product_metadata['version']):]
assert re.search(r'\bstatic\s+let\s+semanticVersion\s*=\s*version\s*\+\s*"'+re.escape(semantic_suffix)+r'"',product_source), 'Core and Info semantic versions differ'
assert 'SUFeedURL' not in info and 'SUPublicEDKey' not in info,'Review this gate when the project publishes its own signed updates.'
(root/'docs/APP_STRINGS.json').write_text(json.dumps(sorted(keys),ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'unchangedSharedFiles':len(provenance['files']),'translatedStaticStrings':len(keys-error_keys-activity_keys),'translatedDynamicErrorStrings':len(error_keys),'translatedDynamicActivityStrings':len(activity_keys),'translatedTotalStrings':len(keys),'languages':list(tables),'product':info['CFBundleDisplayName'],'displayVersion':product_metadata['displayVersion'],'releaseChannel':product_metadata['releaseChannel'],'prereleaseNumber':product_metadata['prereleaseNumber']},indent=2))
