# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "coreai-core==1.0.0b2",
#   "coreai-torch==0.4.1",
#   "transformers==4.57.3",
# ]
# [tool.uv]
# index-url = "https://pypi.org/simple"
# prerelease = "allow"
# index-strategy = "unsafe-best-match"
# ///
"""Compare Core AI's exact input/output with the pinned original F32 weights."""
import argparse,base64,json,pathlib,time
import numpy as np
import torch
from transformers import AutoModelForObjectDetection
p=argparse.ArgumentParser();p.add_argument('probe');p.add_argument('--output',required=True);p.add_argument('--coreai-dtype',choices=['float32','float16'],default=None);p.add_argument('--reference-dtype',choices=['float32','float16'],default='float32');args=p.parse_args()
probe=json.loads(pathlib.Path(args.probe).read_text())
inputs=np.frombuffer(base64.b64decode(probe['inputFloat32']),dtype='<f4').copy().reshape(probe['inputShape'])
model=AutoModelForObjectDetection.from_pretrained('hustvl/yolos-tiny',revision='95a90f3c189fbfca3bcfc6d7315b9e84d95dc2de',local_files_only=True).eval().float()
dtype=torch.float16 if args.reference_dtype=='float16' else torch.float32
model=model.to(dtype)
start=time.monotonic()
with torch.inference_mode(), torch.autocast(device_type='cpu',dtype=dtype,enabled=dtype==torch.float16): outputs=model(pixel_values=torch.from_numpy(inputs).to(dtype))
reference=outputs.logits.numpy().astype(np.float64);actual=np.asarray(probe['logits']).reshape(probe['logitsShape'])
boxes=outputs.pred_boxes.numpy().astype(np.float64);actual_boxes=np.asarray(probe['boxes']).reshape(boxes.shape)
logit_error=np.abs(reference-actual);box_error=np.abs(boxes-actual_boxes)
# Set before collecting the first result: F16 graph vs original F32 model.
limits={'logitsMeanAbsolute':0.03,'logitsMaxAbsolute':0.2,'boxesMaxAbsolute':0.01}
metrics={'logitsMeanAbsolute':float(logit_error.mean()),'logitsMaxAbsolute':float(logit_error.max()),'boxesMaxAbsolute':float(box_error.max()),'classAgreement':float((reference.argmax(-1)==actual.argmax(-1)).mean())}
result={'referenceModel':'hustvl/yolos-tiny','revision':'95a90f3c189fbfca3bcfc6d7315b9e84d95dc2de','referenceDtype':args.reference_dtype,'coreAIDtype':probe.get('inputScalarType',args.coreai_dtype or 'unknown'),'inputShape':probe['inputShape'],'samePreprocessedInput':True,'limits':limits,'metrics':metrics,'referenceSeconds':time.monotonic()-start,'passed':all(metrics[k]<=v for k,v in limits.items())}
pathlib.Path(args.output).write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if not result['passed']:raise SystemExit(1)
