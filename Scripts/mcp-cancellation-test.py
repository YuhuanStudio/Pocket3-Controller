#!/usr/bin/env python3
"""Verify real MCP cancellation forwarding without any camera hardware."""
import json,os,pathlib,select,selectors,socket,subprocess,tempfile,threading,time,uuid
root=pathlib.Path(__file__).resolve().parents[1];out=root/'artifacts/mcp-cancellation';out.mkdir(parents=True,exist_ok=True)
started=threading.Event();cancelled=threading.Event();requests=[]
with tempfile.TemporaryDirectory(prefix='p3-mcp-',dir='/tmp') as directory:
 directory=pathlib.Path(directory);token=uuid.uuid4().hex;(directory/'connection-token').write_text(token)
 listener=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);listener.bind(str(directory/'bridge.sock'));listener.listen(8);listener.settimeout(.2)
 done=threading.Event()
 def handle(connection):
  try:
   request=json.loads(connection.makefile('rb').readline());assert request['token']==token
   requests.append(request['operation'])
   if request['operation']=='move':
    started.set()
    deadline=time.monotonic()+5
    while time.monotonic()<deadline:
     if select.select([connection],[],[],.1)[0] and not connection.recv(1,socket.MSG_PEEK):cancelled.set();break
     if cancelled.is_set():break
   else:
    if request['operation']=='cancel-request':cancelled.set()
    connection.sendall((json.dumps({'id':request['id'],'version':1,'result':{'simulation':True}})+'\n').encode())
  finally:connection.close()
 def accept():
  while not done.is_set():
   try:connection,_=listener.accept()
   except socket.timeout:continue
   except OSError:return
   threading.Thread(target=handle,args=(connection,),daemon=True).start()
 thread=threading.Thread(target=accept,daemon=True);thread.start()
 err=(out/'stderr.log').open('w')
 process=subprocess.Popen([str(root/'dist/Pocket 3 Controller.app/Contents/MacOS/pocket3'),'mcp'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=err,env={**os.environ,'POCKET3_BRIDGE_DIRECTORY':str(directory)})
 selector=selectors.DefaultSelector();selector.register(process.stdout,selectors.EVENT_READ);buffer=bytearray();messages=[]
 def send(message):process.stdin.write((json.dumps(message)+'\n').encode());process.stdin.flush()
 def response(identifier):
  deadline=time.monotonic()+10
  while time.monotonic()<deadline:
   while b'\n' in buffer:
    line,_,tail=buffer.partition(b'\n');buffer[:]=tail;value=json.loads(line);messages.append(value)
    if value.get('id')==identifier:return value
   if selector.select(.1):buffer.extend(process.stdout.read1(65536))
  raise TimeoutError(identifier)
 try:
  send({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'CancellationCheck','version':'1'}}});response(1)
  send({'jsonrpc':'2.0','method':'notifications/initialized'})
  send({'jsonrpc':'2.0','id':2,'method':'tools/call','params':{'name':'move_gimbal','arguments':{'direction':'left'}}})
  assert started.wait(5),'MCP did not forward the move request'
  before=time.monotonic();send({'jsonrpc':'2.0','method':'notifications/cancelled','params':{'requestId':2,'reason':'Offline cancellation test'}})
  assert cancelled.wait(2),'MCP cancellation did not reach the local bridge'
  send({'jsonrpc':'2.0','id':3,'method':'tools/list','params':{}});listing=response(3)
  assert {tool['name'] for tool in listing['result']['tools']} == {'camera_status','capture_frame','move_gimbal','stop_gimbal','camera_zoom_status','camera_set_zoom'}
  assert not any(m.get('id')==2 for m in messages),'Cancelled request produced a response'
  report={'passed':True,'simulation':True,'cancellationSeconds':time.monotonic()-before,'helperRemainedUsable':True,'operationsSeen':requests}
  (out/'result.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
 finally:
  process.stdin.close()
  try:process.wait(timeout=5)
  except subprocess.TimeoutExpired:process.terminate();process.wait(timeout=5)
  done.set();listener.close();thread.join(timeout=1);err.close()
