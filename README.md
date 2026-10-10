# bootc-vllm-xpu

Fedora **45** bootc image that serves an OpenAI-compatible API with
[vLLM XPU](https://github.com/vllm-project/vllm) on an Intel Arc Pro B70
(Battlemage / Xe2), based on the recipes in
[SergiioB/intel-arc-pro-b70-inference-cookbook](https://github.com/SergiioB/intel-arc-pro-b70-inference-cookbook)
and [MikeCaldera/intel-arc-pro-b70-qwen38-vllm](https://github.com/MikeCaldera/intel-arc-pro-b70-qwen38-vllm).

Sibling of `bootc-sycl-llama.cpp`. Unlike that project, nothing is compiled
here: vLLM, PyTorch-XPU and the Intel GPU user-space stack ship inside the
pinned `vllm/vllm-openai-xpu` container, which the host runs as a Podman
**Quadlet**. The host only provides the `xe` kernel driver and `/dev/dri`.

## Layout

| Path | Installed to | Purpose |
|------|--------------|---------|
| `Containerfile` | — | `fedora-bootc:45` + Quadlet + MTP patches |
| `quadlet/vllm.container` | `/usr/share/containers/systemd/` | Generates `vllm.service` (pinned image digest) |
| `quadlet/vllm.env` | `/etc/vllm/vllm.env` | Model path, MTP, `vllm serve` flags |
| `libexec/vllm-xpu-entrypoint` | `/usr/libexec/` | Applies patches, builds `vllm serve` args |
| `tmpfiles.d/vllm.conf` | `/usr/lib/tmpfiles.d/` | Creates `/var/lib/vllm/models` and `/var/lib/vllm/cache` (torch.compile cache) |
| cookbook `patches/patch_mtp_*.py` | `/usr/share/vllm-xpu/patches/` | B70 MTP fixes, fetched at build (`COOKBOOK_REF`) |

## Build and deploy

```bash
cp .env.example .env              # set REGISTRY, pin COOKBOOK_REF to a commit SHA
cp config.toml.example config.toml
./build.sh --push                 # tags: f45-YYYYMMDD, f45, latest
./create-disk-image.sh --type iso
```

Existing bootc host: `sudo bootc switch <registry>/bootc-vllm-xpu:f45 && sudo systemctl reboot`.

### Rebasing from `bootc-sycl-llama.cpp`

`bootc switch` works directly (also crosses Fedora 44 → 45). `/etc` and `/var`
survive: registry auth in `/etc/ostree/auth.json`, swapfile, and the GGUF
models in `/var/lib/llama/models` remain, so `sudo bootc rollback && sudo systemctl reboot`
returns to llama.cpp intact. `llama-server.service` disappears with the old `/usr`.
Raise VM RAM before switching (see caveats).

## Stage a model

The service is skipped until `/var/lib/vllm/models` is non-empty. vLLM uses
Hugging Face safetensors (GPTQ), **not GGUF**.

```bash
sudo hf download SergiioB/Qwen3.8-27B-GPTQ-Int4-sym-G128-MTP-BF16 \
  --revision 9d189a60e4c0ad7f9f47cd94bfa393ca10b3924e \
  --local-dir /var/lib/vllm/models/Qwen3.8-27B-GPTQ-Int4-sym-G128-MTP-BF16
sudo systemctl start vllm        # first start: image pull + ~90 s JIT compile; later starts reuse the cache (~1 min)
journalctl -fu vllm
curl -f http://localhost:8000/health
```

Change model or flags in `/etc/vllm/vllm.env`, then `sudo systemctl restart vllm`.
A new model or changed compile-affecting flags trigger one fresh compile; the
result is cached in `/var/lib/vllm/cache` (safe to delete to force a rebuild).

- `hf download` often hits `The read operation timed out` on large shards; it
  resumes automatically, and if it gives up (`Max retries exceeded`), rerun the
  same command — finished files are skipped. `huggingface-cli` is a deprecated
  stub; use `hf`. `hf_xet` is not packaged in Fedora 45 (plain HTTP fallback).
- Verify all shards are present: `ls <model-dir>/*.safetensors | wc -l`.

### Startup and memory (Qwen3.8-27B G128, MTP4, `--max-model-len 100000`)

| Phase | First start | Cached restart |
|---|---:|---:|
| Image pull (`Pull=missing`) | ~80 s | — |
| Weights + MTP drafter load | ~13 s | ~13 s |
| torch.compile (`init engine`) | ~92 s | **~1 s** (`Directly load AOT compilation`) |
| Total to `Application startup complete` | ~3.5 min | **< 1 min** |

- GPU: 17.38 GiB weights, 2.86 GiB peak activation; at `--gpu-memory-utilization 0.88`
  the KV cache gets 5.51 GiB = **134,210 tokens** (1.34× the 100k context). vLLM
  reports up to 7.98 GiB available, so ~160k context fits at `0.90` (upstream-tested).
- Host RAM peak during load: ~27 GiB (`systemctl status vllm`).

Harmless log noise: `[ERROR] min_frames/max_frames ... not documented` (transformers
docstring check), `Falling back to the Triton GDN decode path` (fused kernel is
CUDA-only), `CCL_WARN`, `XPU Graph support is experimental`.

## Using the API

OpenAI-compatible on port 8000, model name `qwen38`. Qwen3.8 is a thinking model:
`--reasoning-parser qwen3` returns the chain of thought in `message.reasoning`
and the answer in `message.content`.

- Thinking can take thousands of tokens; a low `max_tokens` ends with
  `finish_reason: "length"` and `content: null`. Use ≥ 4096.
- Disable thinking per request for quick tasks:
  `"chat_template_kwargs": {"enable_thinking": false}`.
- Sampling defaults come from the model's `generation_config.json`
  (temperature 1.0, top-k 20, top-p 0.95).

```bash
curl -s http://localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"qwen38","messages":[{"role":"user","content":"Hello"}],"max_tokens":4096}'
journalctl -u vllm | grep -E 'throughput|SpecDecoding'   # decode t/s, MTP acceptance
```

## Performance

`vllm bench serve` against the running server (VM with a B70 SR-IOV VF, Qwen3.8-27B
GPTQ G128 + MTP4, fp8 KV, concurrency 1, random prompts, `--ignore-eos`):

```bash
sudo podman exec vllm vllm bench serve --backend vllm --base-url http://127.0.0.1:8000 \
  --model qwen38 --tokenizer /models/Qwen3.8-27B-GPTQ-Int4-sym-G128-MTP-BF16 \
  --dataset-name random --random-input-len 512 --random-output-len 128 \
  --num-prompts 10 --max-concurrency 1 --ignore-eos --temperature 0
```

| Prompt / sampling | Prefill (input ÷ TTFT) | Decode (1000 ÷ TPOT) | Step (ITL) | MTP accept / length |
|---|---:|---:|---:|---:|
| 512, temp 1.0 (model default) | ~1,340 t/s | 40 t/s | 58.6 ms | 34.8 % / 2.39 |
| 512, **temp 0** | ~1,420 t/s | **62 t/s** (median 70) | 57.4 ms | 65.4 % / 3.61 |
| 16,384, temp 1.0 | **~1,530 t/s** | 32 t/s | 64.0 ms | 27.3 % / 2.09 |

- Step time is ~constant; decode speed = accepted tokens per step ÷ step time,
  so **sampling temperature dominates** (greedy ≈ +55 %).
- **Context depth costs little**: 512 → 16k slows a step by only ~12 %, because
  Qwen3.8 is a hybrid (Gated DeltaNet linear attention + full attention) model.
- For comparison, llama.cpp SYCL on the same VF ran **Gemma 4 12B** at 462 t/s
  prefill / 45 t/s decode (d0) and 350 / 21 t/s at 16k depth.
- The cookbook's 84.65 t/s (bare metal) implies a ~43 ms step vs ~57 ms here;
  likely VF/VM overhead, power limit, or their custom runtime image.
- **Keep MTP4**: under greedy decoding the 4th draft is still accepted 48 % of
  the time. MTP3 (`num_speculative_tokens: 3`) may only pay off at temperature 1.0,
  where position 4 drops to 8–20 %.
- `vllm bench serve` uses random tokens on `/v1/completions` (no thinking, no chat
  template), which understates MTP acceptance versus real text; real chat at
  temperature 1.0 measured ~46 t/s.

## Pinning and updates

- The **vLLM image digest** (`quadlet/vllm.container`) and the **cookbook ref**
  (`COOKBOOK_REF`) are a matched pair: the patches edit vLLM's source in place
  and break on other builds. Bump them together, following the cookbook's
  `docs/IMAGE-AND-PATCH-MATRIX.md`.
- The image is pulled on first start (`Pull=missing`), not baked in, so
  `bootc upgrade` stays small.
- **`/etc/vllm/vllm.env` is not replaced on upgrade once edited locally** (bootc
  three-way `/etc` merge keeps your copy). If a new image changes the env
  variables (e.g. the `VLLM_*` → `SERVE_*` rename), the service fails until you
  refresh it: `sudo cp /usr/share/vllm-xpu/vllm.env /etc/vllm/vllm.env`, re-apply
  your edits, then restart. Settings use `SERVE_*` because vLLM warns about any
  unknown `VLLM_*` variable.

## Host requirements and caveats

- **RAM:** ≥ 32 GiB recommended. Loading ~18 GB of weights plus inductor JIT
  needs far more host memory than llama.cpp.
- **SR-IOV VF in a VM works** (verified: B70 VF passed through to a VM, 30 GiB visible).
  Upstream tests on bare metal only. An Xe driver wedge (`/health` hangs,
  `dmesg | grep -iE 'xe|wedged'`) may need a host reboot.
- **Prefix caching is off** (`--no-enable-prefix-caching`): with MTP it causes
  silent output corruption on this stack. Each request re-prefills its full
  prompt, which costs time in long agent sessions.
- `UR_RESULT_ERROR_OUT_OF_DEVICE_MEMORY` → lower `--max-model-len` or
  `--gpu-memory-utilization` in `SERVE_ARGS`.
- `UR_RESULT_ERROR_OUT_OF_RESOURCES` during compile → uncomment
  `TORCHINDUCTOR_COMPILE_THREADS=1` in `vllm.env`.
- **SELinux:** the Quadlet sets `SecurityLabelDisable=true`. Without it, SELinux
  blocks the container from opening `/dev/dri`.
