#!/usr/bin/env python3
"""Apply project-owned public update settings to a staging bundle's Info.plist."""
import argparse,base64,json,pathlib,plistlib,urllib.parse
ALLOWED={'repositoryURL','feedURL','publicEDKey'}
def settings(value):
 if not isinstance(value,dict) or set(value)-ALLOWED:raise ValueError('Only repositoryURL, feedURL and publicEDKey are accepted; never put a private key in release settings.')
 def url(key):
  text=value.get(key)
  if text is None:return None
  if not isinstance(text,str):raise ValueError(key+' must be an HTTPS URL')
  parsed=urllib.parse.urlsplit(text)
  if parsed.scheme!='https' or not parsed.hostname or parsed.username is not None or parsed.password is not None:raise ValueError(key+' must be an HTTPS URL without credentials')
  if '/yunaudio/' in parsed.path.lower() or parsed.path.lower().rstrip('/').endswith('/yunaudio'):raise ValueError('Use this project\'s update source, not the YunAudio repository.')
  return text
 result={}
 repository=url('repositoryURL');feed=url('feedURL');key=value.get('publicEDKey')
 if (feed is None)!=(key is None):raise ValueError('feedURL and publicEDKey must be configured together')
 if key is not None:
  if not isinstance(key,str):raise ValueError('publicEDKey must be base64')
  try:decoded=base64.b64decode(key,validate=True)
  except (ValueError,TypeError) as error:raise ValueError('publicEDKey must be base64') from error
  if len(decoded)!=32:raise ValueError('publicEDKey must decode to 32 bytes')
  result.update(SUFeedURL=feed,SUPublicEDKey=key,SURequireSignedFeed=True,SUVerifyUpdateBeforeExtraction=True)
 if repository:result['Pocket3RepositoryURL']=repository
 return result

def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('settings',type=pathlib.Path);parser.add_argument('--info-plist',type=pathlib.Path);args=parser.parse_args()
 try:updates=settings(json.loads(args.settings.read_text()))
 except (ValueError,OSError) as error:raise SystemExit(str(error))
 if args.info_plist:
  info=plistlib.loads(args.info_plist.read_bytes());info.update(updates)
  args.info_plist.write_bytes(plistlib.dumps(info,sort_keys=False))
 print(json.dumps({'updatesConfigured':'SUFeedURL' in updates,'repositoryConfigured':'Pocket3RepositoryURL' in updates}))
if __name__=='__main__':main()
