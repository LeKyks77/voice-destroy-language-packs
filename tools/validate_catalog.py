from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LANGUAGE_ID = re.compile(r"^[a-z]{2,3}_[a-z0-9]{2,8}$")
VARIANT_ID = re.compile(r"^[a-z0-9_-]{2,16}$")
SHA256 = re.compile(r"^[A-Fa-f0-9]{64}$")
MAX_ARCHIVE = 2 * 1024 * 1024 * 1024
MOJIBAKE_MARKERS = (
    "\u00c3\u00a9", "\u00c3\u00a8", "\u00c3\u00aa", "\u00c3\u00a0", "\u00c3\u00a2",
    "\u00c3\u00b4", "\u00c3\u00b9", "\u00c3\u00bb", "\u00c3\u00a7", "\u00c3\u00b1",
    "\u00c2\u00b7", "\u00e2\u20ac\u2122", "\u00e2\u20ac\u0153", "\u00e2\u20ac", "\ufffd",
)


def validate_text_encoding(value: object, context: str) -> None:
    if isinstance(value, str):
        marker = next((candidate for candidate in MOJIBAKE_MARKERS if candidate in value), None)
        require(marker is None, f"{context}: probable broken UTF-8 text")
    elif isinstance(value, dict):
        for key, child in value.items():
            validate_text_encoding(child, f"{context}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            validate_text_encoding(child, f"{context}[{index}]")


def read_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected a JSON object")
    validate_text_encoding(value, str(path.relative_to(ROOT)))
    return value


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def validate_manifest() -> None:
    manifest = read_json(ROOT / "manifest.json")
    require(manifest.get("schema_version") == 2, "manifest: schema_version must be 2")
    languages = manifest.get("languages")
    require(isinstance(languages, list) and languages, "manifest: languages must not be empty")
    seen_languages: set[str] = set()
    for language in languages:
        language_id = language.get("id", "")
        require(bool(LANGUAGE_ID.fullmatch(language_id)), f"invalid language id: {language_id}")
        require(language_id not in seen_languages, f"duplicate language: {language_id}")
        seen_languages.add(language_id)
        variants = language.get("variants")
        require(isinstance(variants, list) and variants, f"{language_id}: variants must not be empty")
        seen_variants: set[str] = set()
        for variant in variants:
            variant_id = variant.get("id", "")
            require(bool(VARIANT_ID.fullmatch(variant_id)), f"{language_id}: invalid variant {variant_id}")
            require(variant_id not in seen_variants, f"{language_id}: duplicate variant {variant_id}")
            seen_variants.add(variant_id)
            size = variant.get("archive_size", 0)
            require(isinstance(size, int) and 0 < size <= MAX_ARCHIVE,
                    f"{language_id}/{variant_id}: invalid archive size")
            require(bool(SHA256.fullmatch(variant.get("sha256", ""))),
                    f"{language_id}/{variant_id}: invalid SHA-256")
            require(str(variant.get("download_url", "")).startswith("https://"),
                    f"{language_id}/{variant_id}: download URL must use HTTPS")
            require(int(variant.get("runtime_memory_mb", 0)) > 0,
                    f"{language_id}/{variant_id}: runtime memory is missing")


def validate_sources() -> None:
    index = read_json(ROOT / "tools" / "model-sources.json")
    for directory in sorted((ROOT / "sources").iterdir()):
        if not directory.is_dir():
            continue
        descriptor = read_json(directory / "pack.json")
        dictionary = read_json(directory / "dictionary.json")
        language_id = directory.name
        require(descriptor.get("schema_version") == 2, f"{language_id}: source schema must be 2")
        require(descriptor.get("id") == language_id, f"{language_id}: source id mismatch")
        require(dictionary.get("language") == language_id, f"{language_id}: dictionary id mismatch")
        require(isinstance(dictionary.get("aliases"), list), f"{language_id}: aliases must be an array")
        sources = index.get(language_id)
        require(isinstance(sources, dict), f"{language_id}: model source index is missing")
        seen: set[str] = set()
        for variant in descriptor.get("variants", []):
            variant_id = variant.get("id", "")
            require(bool(VARIANT_ID.fullmatch(variant_id)), f"{language_id}: invalid source variant")
            require(variant_id not in seen, f"{language_id}: duplicate source variant {variant_id}")
            seen.add(variant_id)
            source = sources.get(variant_id)
            require(isinstance(source, dict), f"{language_id}/{variant_id}: source archive is missing")
            require(int(source.get("archive_size", 0)) > 0, f"{language_id}/{variant_id}: source size missing")
            require(bool(SHA256.fullmatch(source.get("sha256", ""))),
                    f"{language_id}/{variant_id}: source SHA-256 invalid")


if __name__ == "__main__":
    validate_manifest()
    validate_sources()
    print("Voice Destroy language catalog is valid.")
