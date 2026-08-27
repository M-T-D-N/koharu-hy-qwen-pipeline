from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer


ROOT = Path(__file__).resolve().parents[1]
MODEL_PATH = Path(os.environ.get("KOHARU_HY_MODEL_PATH", ROOT / "models" / "hy-mt2-7b"))
REVISION = "9b0eb4e8f001def3e5ff6469a0ac96fdb39ec223"
PROMPT = "Translate the following text into Korean. Note that you should only output the translated result without any additional explanation:\n\n{source_text}"


def atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    os.replace(temporary, path)


def main() -> None:
    parser = argparse.ArgumentParser(description="GPU-only pinned Hy-MT2 request worker.")
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--max-new-tokens", type=int, default=128)
    args = parser.parse_args()

    request = json.loads(args.input.read_text(encoding="utf-8"))
    segments = request.get("segments")
    if not isinstance(segments, list) or not segments:
        raise SystemExit("request must contain at least one segment")
    if not torch.cuda.is_available():
        raise SystemExit("CUDA is required; CPU fallback is not permitted")
    if not (MODEL_PATH / "download-manifest.json").is_file():
        raise SystemExit(f"pinned model is incomplete: {MODEL_PATH}")

    tokenizer = AutoTokenizer.from_pretrained(MODEL_PATH, local_files_only=True, trust_remote_code=False)
    tokenizer.padding_side = "left"
    if tokenizer.pad_token_id is None:
        tokenizer.pad_token = tokenizer.eos_token
    model = AutoModelForCausalLM.from_pretrained(
        MODEL_PATH,
        local_files_only=True,
        dtype=torch.bfloat16,
        device_map={"": 0},
        trust_remote_code=False,
    ).eval()
    devices = {parameter.device.type for parameter in model.parameters()}
    if devices != {"cuda"}:
        raise RuntimeError(f"GPU-only load required, observed devices: {sorted(devices)}")

    torch.cuda.reset_peak_memory_stats()
    translated: list[dict[str, object]] = []
    started_all = time.perf_counter()
    for offset in range(0, len(segments), args.batch_size):
        batch = segments[offset : offset + args.batch_size]
        prompts = [PROMPT.format(source_text=str(item["text"])) for item in batch]
        conversations = [[{"role": "user", "content": prompt}] for prompt in prompts]
        inputs = tokenizer.apply_chat_template(
            conversations,
            add_generation_prompt=True,
            padding=True,
            return_tensors="pt",
            return_dict=True,
        ).to("cuda")
        input_tokens = inputs["input_ids"].shape[-1]
        with torch.inference_mode():
            output = model.generate(
                **inputs,
                max_new_tokens=args.max_new_tokens,
                do_sample=False,
                repetition_penalty=1.05,
                pad_token_id=tokenizer.pad_token_id,
            )
        for row, item in enumerate(batch):
            text = tokenizer.decode(output[row, input_tokens:], skip_special_tokens=True).strip()
            translated.append({"id": int(item["id"]), "text": text})

    atomic_json(
        args.output,
        {
            "model": "hy-mt2-7b",
            "model_revision": REVISION,
            "translations": translated,
            "elapsed_seconds": round(time.perf_counter() - started_all, 6),
            "torch_peak_allocated_bytes": torch.cuda.max_memory_allocated(),
            "cuda_device": torch.cuda.get_device_name(0),
        },
    )


if __name__ == "__main__":
    main()
