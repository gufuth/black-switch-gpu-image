FROM runpod/comfyui:cuda12.8

ENV COMFY=/opt/comfyui-baked \
    PIP_NO_CACHE_DIR=1 \
    DEBIAN_FRONTEND=noninteractive

# 1. Freeze numpy + torch to the base image's EXACT versions so nothing below bumps them.
#    (numpy>=2 breaks the container's scipy; a torch bump breaks CUDA. Both were real hazards.)
RUN python3 - <<'PY' > /opt/constraints.txt
import importlib.metadata as m
for p in ("numpy","torch","torchvision","torchaudio"):
    try: print(p + "==" + m.version(p))
    except Exception: pass
PY
ENV PIP_CONSTRAINT=/opt/constraints.txt

# 2. Bake EXACTLY the deps our proven per-boot bring_up installs. A cold pod never pip-installs the
#    render dependencies again. The constraint file + a final `pip check` guard against numpy/torch drift.
RUN python3 -m pip install --no-cache-dir \
        gguf diffusers transformers einops accelerate omegaconf easydict ftfy \
        sentencepiece protobuf imageio-ffmpeg av && \
    python3 -m pip check || echo "WARN: pip check reported issues (non-fatal; inspect build log)"

# 3. Bake model weights INTO THE BAKED SOURCE (/opt/comfyui-baked), NOT the runtime workspace dir.
#    RunPod's start.sh copies /opt/comfyui-baked -> /workspace/runpod-slim/ComfyUI ONLY IF that dir
#    does not already exist. Baking into the runtime dir pre-creates it and SKIPS the copy, so
#    ComfyUI's own main.py never lands and the server never starts. Baking into the source dir keeps
#    the native launch intact and carries our models along. We deliberately set NO ENTRYPOINT/CMD â€”
#    the base image's start.sh launches ComfyUI natively (native Wan nodes ship in the base image).
ARG BAKE_MODELS=0
COPY models.txt /opt/models.txt
RUN if [ "${BAKE_MODELS}" = "1" ]; then set -eux; \
      while read -r dest url; do \
        [ -z "${dest}" ] && continue; case "${dest}" in \#*) continue;; esac; \
        mkdir -p "$(dirname "${COMFY}/models/${dest}")"; \
        echo "baking ${dest}"; curl -fL --retry 3 -o "${COMFY}/models/${dest}" "${url}"; \
      done < /opt/models.txt; \
      ls -lhR "${COMFY}/models/diffusion_models" "${COMFY}/models/text_encoders" "${COMFY}/models/vae"; \
    else echo "BAKE_MODELS=0 â€” models read from the network volume at runtime"; fi

EXPOSE 8188
