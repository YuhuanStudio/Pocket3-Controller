#!/usr/bin/env python3
"""Pure validation rules shared by the Pocket 3 format-matrix runner/tests."""
import statistics

def validate_samples(mode, pixel_format, device_id, session_id, samples):
    if not samples:
        raise RuntimeError('No status samples were collected')
    if any(sample.get('session') != session_id for sample in samples):
        raise RuntimeError('Camera session changed during a format trial.')
    shape_ok = all(
        sample.get('width') == mode['width'] and sample.get('height') == mode['height']
        and sample.get('deviceID') == device_id and sample.get('inputPixelFormat') == pixel_format
        and sample.get('outputPixelFormat') == 'BGRA'
        and isinstance(sample.get('rotationDegrees'), int) and isinstance(sample.get('mirrored'), bool)
        and isinstance(sample.get('age'), (int, float)) and 0 <= sample['age'] < 1
        for sample in samples)
    if not shape_ok:
        raise RuntimeError('Received shape/format/freshness mismatch')
    if len(samples) > 1 and samples[-1]['frames'] <= samples[0]['frames']:
        raise RuntimeError('Video did not advance')
    fps = statistics.median(sample['fps'] for sample in samples)
    tolerance = max(1, mode['frameRate'] * .05)
    if abs(fps - mode['frameRate']) > tolerance:
        raise RuntimeError('Measured rate does not match requested rate')
    return fps, tolerance
