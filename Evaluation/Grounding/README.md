# Public image grounding evaluation

This small regression set uses six COCO val2017 photographs and 18 tasks. Each photograph has an annotated object count, the center point of its leftmost target instance, and a request for an absent object. The repository contains metadata, prompts, and annotations only. Photographs are downloaded into the ignored `Evaluation/Grounding/images/` cache and are never bundled with the App, README screenshots, or release assets.

| COCO image | Target | Annotated count | Absent target | Image license recorded by COCO |
|---|---|---:|---|---|
| 29596 | Chair | 2 | Elephant | CC BY 2.0 |
| 54605 | Cup | 2 | Bicycle | CC BY 2.0 |
| 132329 | Bottle | 4 | Giraffe | CC BY 2.0 |
| 127182 | Potted plant | 1 | Motorcycle | CC BY 2.0 |
| 58111 | Cat | 1 | Dog | CC BY 2.0 |
| 27620 | Laptop | 1 | Zebra | CC BY-SA 2.0 |

`manifest.json` records the original COCO and Flickr URLs, Flickr photo pages, full license URLs, image sizes and SHA-256 hashes, annotation IDs and bounding boxes, prompts, and expected results. Its `derivedFromManifestSHA256` identifies the original local pilot manifest; the 18 tasks and six image records are unchanged. The original pilot reports remain independent historical evidence.

## Prepare and validate

Run from the repository root. Preparation downloads only these six photographs, about 755 KB combined; it does not download the complete dataset, models, or annotations archive. Existing matching files are reused. Each new download must match its exact size and SHA-256 before an atomic replacement of its cache file. Redirected URLs, unexpected sizes, and changed content are rejected.

```sh
python3 Scripts/evaluate-ai-grounding.py --prepare-data
python3 Scripts/evaluate-ai-grounding.py --self-test
python3 Scripts/evaluate-ai-grounding.py --validate-only
python3 Scripts/evaluate-ai-grounding.py --endpoint typed --validate-only
```

These modes do not contact or launch the App, access a camera, or run a model. Normal evaluation never downloads missing data automatically.

## Run models

An already-running development App launched with `--hardware-validation` is required. The runner defaults to the installed helper in `/Applications/Pocket 3 Controller.app`. It does not change access permissions, connect hardware, download or unload models, restart the App, or switch networks.

```sh
# One image, three tasks, two engines.
python3 Scripts/evaluate-ai-grounding.py --limit 3 --engines apple mlx

# All 18 tasks for each engine.
python3 Scripts/evaluate-ai-grounding.py --engines apple mlx

# Native typed output requires an App build supporting evaluate-grounding.
python3 Scripts/evaluate-ai-grounding.py --endpoint typed --engines apple mlx
```

`--endpoint legacy` is the default and calls `evaluate-image`, requesting JSON inside `ObservationAnswer.answer`. `--endpoint typed` calls `evaluate-grounding --kind count|point|absent`, using its native structured result. The typed prompt removes the legacy JSON-wrapper instructions from the existing question; it does not derive a prompt from the expected count or position. The two contracts are reported separately and should not be described as identical prompts.

Each run creates a unique `artifacts/ai-grounding/<timestamp>-<uuid>/` directory. An explicitly supplied `--output` must not already exist. The default per-request timeout is 140 seconds and the whole-run deadline is 30 minutes. A timeout stops further requests; termination of the App's request still needs an AI-idle check. The runner does not issue a global cancellation that could affect another task.

## Scoring and interpretation

The report separates JSON parsing, schema validity, factual accuracy, and complete task success. Counts require exact agreement with the selected COCO annotations. Points must fall inside the target's bounding box; distance to its annotated center is also recorded. The absent task succeeds only when the model declines to invent a position. Schema-valid uncertainty is distinct from a successful known-target answer.

Native point objects `{x,y}` may be represented as arrays for scoring. Values are never rescaled, clamped, rounded, or repaired using ground truth. Coordinates outside the requested top-left-origin `[0,1]` space do not become correct by assuming a different unit. Host `grounding_output_invalid` rejections are recorded without inventing the rejected model output. Returned frame provenance must identify `local-evaluation` / `local_image_import` and the expected image dimensions.

COCO is widely used in pretraining. This is a reproducible smoke/regression set, **not an unseen or contamination-free benchmark**. Six images cannot establish general model rankings or reliable physical camera control. COCO annotations may omit visible objects and use category boundaries different from everyday language. The selected counts and negatives were visually checked by a coding assistant, not independently adjudicated by a human annotator. An axis-aligned box can include background, so an inside-box point does not establish segmentation or correct autofocus placement.

Timing includes the CLI, IPC, and model work. Cold loading is not automatically separated from warm inference. Keep repeated and cold/warm trials distinct when comparing models. A format failure is not automatically a perceptual error: free text may describe the correct count while violating the machine-readable contract.

## Recorded baseline: build 21

The first complete typed run issued 36 requests, 18 per engine, using this unchanged six-image dataset. [The metadata-only result](results/build21-typed.json) records source commit `35eded8dea943150cc755c21e9bd3a79c5e8992b`, the App executable hash, prompts, expected values, returned typed values, and individual scores. It contains no photographs or private filesystem paths.

| Metric | Apple system model | MLX Qwen3.5-4B 4-bit |
|---|---:|---:|
| Complete tasks passed | 6 / 18 | 14 / 18 |
| Count | 5 / 6 | 5 / 6 |
| Point inside target bbox | 1 / 6 | 6 / 6 |
| Valid absent-target abstention | 0 / 6 | 3 / 6 |
| Returned schema-valid results | 12 / 18 | 15 / 18 |
| Host output rejections | 6 / 18 | 3 / 18 |
| Whole-request p50 | 1.043 s | 1.148 s |
| Whole-request p95 | 1.210 s | 1.337 s |

Each task ran Apple followed by MLX once, in a process where both engines had already been exercised by a pilot. These timings are not isolated cold-load or sustained-memory measurements. The six successful MLX points establish only this small inside-bbox check, not general grounding or camera-control reliability. Both models still made one count error each.

All nine host rejections occurred on absent-target tasks. The API rejected those outputs before returning their contents, so their underlying visual judgments are unavailable. They count as end-to-end failures, but must not be relabeled as hallucinated objects without evidence. The exported records explicitly preserve that distinction.

A subsequent standalone Apple diagnostic used the same image, prompt, type structure, and preprocessing for one absent-target case. Across three alternating trials per variant, default `@Generable` returned `found=false` with point `(0,0)`, while `representNilExplicitlyInGeneratedContent: true` returned `found=false` with a nil point, explicitly null in `generatedContent`. This motivated a source fix for the optional Location and Presence types plus a generated-content regression check. It is a single-case diagnostic, not proof that all failures share that cause or that a displayed schema JSON necessarily changes.

## Build 22 full-dataset rerun

[Build 22 metadata](results/build22-typed.json) records a separate 36-request rerun of the same manifest, tasks, prompts, and point-scoring rules. The source commit is `dc3595c846fc7d8a45fea6432b9db9f788117fec`; no camera or control tools were used, and no new model was downloaded. Historical build 21 results remain unchanged.

| Metric | Apple system model | MLX Qwen3.5-4B 4-bit |
|---|---:|---:|
| Complete tasks passed | 12 / 18 | 14 / 18 |
| Count | 5 / 6 | 5 / 6 |
| Point inside target bbox | 1 / 6 | 6 / 6 |
| Valid absent-target abstention | 6 / 6 | 3 / 6 |
| Returned schema-valid results | 18 / 18 | 15 / 18 |
| Host output rejections | 0 / 18 | 3 / 18 |
| Whole-request p50 | 1.008 s | 1.113 s |
| Whole-request p95 | 1.222 s | 1.366 s |

The Apple absent-target cases now return valid abstentions in this six-case set, after explicit-nil generation was integrated. Its point success remains 1 / 6, so the representation fix does not establish reliable Apple grounding. MLX still has three host rejections whose raw content is unavailable; they remain end-to-end failures without a factual hallucination label. One count error remains for each model.

A pilot preceded the rerun and cached models were reused. Each task ran Apple then MLX once. These are version-regression observations, not a general model ranking, a cold-load benchmark, or proof of physical autofocus/tracking. The same build passed its offline software/package gate and an actual App image-workspace smoke test, including ask/count/location/OCR and cancellation/source replacement without camera-state changes. Short-video input, interactive ROI, continuous tracking, event timelines, and a VLA policy remain future work. See the [AI research report](../../docs/AI_RESEARCH.md) for the bounded evidence and remaining requirements.

## Sources and licenses

The [COCO Consortium's original Terms of Use](https://cocodataset.org/dataset/termsofuse.htm) license annotations under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/legalcode) and state that the Consortium does not own the photographs. Individual image licenses remain the historical Flickr records preserved in the manifest: [CC BY 2.0](https://creativecommons.org/licenses/by/2.0/) or [CC BY-SA 2.0](https://creativecommons.org/licenses/by-sa/2.0/). Consult the recorded original Flickr photo page before redistributing an image; the COCO annotation file does not supply its author's name. This project distributes no photographs with this evaluation metadata.

The annotations were extracted from the [official COCO 2017 train/validation annotation archive](http://images.cocodataset.org/annotations/annotations_trainval2017.zip), available from the [COCO download page](https://cocodataset.org/#download). Archive SHA-256: `113a836d90195ee1f884e704da6304dfaaecff1f023f49b6ca93c4aaae470268`. The `annotations/instances_val2017.json` member SHA-256 is `e8c7f7908f1d7278341fae127d0da654f102f11bd7b21d8aeefa635b8c810b6f`.

The preparation URLs use the official bucket's HTTPS S3 alias. At dataset selection, the `images.cocodataset.org` HTTPS hostname had a certificate mismatch; the S3 alias and official HTTP archive URL returned matching length and ETag. TLS verification was not disabled. The source manifest records the exact retrieval URL, hashes, and retrieval time. Reproducing this small benchmark does not require downloading the archive again.
