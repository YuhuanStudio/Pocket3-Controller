#!/usr/bin/env python3
"""Reproducible compatibility patch for the pinned MLX/Foundation Models bridge.

Xcode 27 beta's metadata channel accepts Codable & Equatable values. Upstream's
bridge hands it ConvertibleToGeneratedContent instead. Preserve the JSON value
using MLXLMCommon's existing Codable representation; never change inference data.
"""
from pathlib import Path
import stat

root = Path(__file__).resolve().parents[1]
path = root / ".build/checkouts/mlx-swift-lm/Libraries/MLXFoundationModels/MLXLanguageModel.swift"
old = "await channel.send(.response(entryID: entryID, action: .updateMetadata(values)))"
new = """// Pocket3Bridge: Xcode 27 beta Codable metadata compatibility.
            var compatible: [String: any Sendable & Codable & Equatable] = [:]
            for (key, value) in values {
                let data = Data(value.generatedContent.jsonString.utf8)
                if let json = try? JSONDecoder().decode(MLXLMCommon.JSONValue.self, from: data) {
                    compatible[key] = json
                } else {
                    compatible[key] = value.generatedContent.jsonString
                }
            }
            await channel.send(.response(entryID: entryID, action: .updateMetadata(compatible)))"""
source = path.read_text()
if old in source:
    assert source.count(old) == 1
    path.chmod(path.stat().st_mode | stat.S_IWUSR)
    path.write_text(source.replace(old, new))
elif new not in source:
    raise SystemExit("Pinned MLX source changed; review the metadata compatibility patch")
print("MLX metadata compatibility patch verified")
