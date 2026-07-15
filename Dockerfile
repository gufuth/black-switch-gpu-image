FROM runpod/comfyui:cuda12.8

ENV COMFY=/workspace/runpod-slim/ComfyUI \
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

# 3. Entrypoint (inline). All /wan-vol refs are GUARDED, so with baked models + native nodes this runs
#    volume-LESS: baked weights sit in the default ${COMFY}/models dirs and native Wan nodes are in the
#    base image; the volume symlink/yaml lines simply no-op when no volume is attached.
RUN cat > /opt/bs_entrypoint.sh <<'EOS' && chmod +x /opt/bs_entrypoint.sh
#!/bin/bash
set -u
COMFY="${COMFY:-/workspace/runpod-slim/ComfyUI}"
VOL="/wan-vol"
log(){ echo "[bs-entrypoint $(date +%H:%M:%S)] $*"; }
pkill -f 'main.py' 2>/dev/null; sleep 1
cat > "${COMFY}/extra_model_paths.yaml" <<YAML
wan_vol:
  base_path: ${VOL}/ComfyUI
  checkpoints: models/checkpoints
  diffusion_models: models/diffusion_models
  unet: models/diffusion_models
  text_encoders: models/text_encoders
  clip: models/text_encoders
  vae: models/vae
  loras: models/loras
YAML
mkdir -p "${COMFY}/models"
[ -d "${VOL}/ComfyUI/models/mmaudio" ] && ln -sfn "${VOL}/ComfyUI/models/mmaudio" "${COMFY}/models/mmaudio" || true
# Symlink the volume's EXACT custom nodes IF a volume is attached (no-op on volume-less native deploys).
if [ -d "${VOL}/ComfyUI/custom_nodes" ]; then
  for d in "${VOL}/ComfyUI/custom_nodes"/*/; do
    n="$(basename "$d")"; ln -sfn "$d" "${COMFY}/custom_nodes/$n"
  done
fi
if [ -f "${VOL}/ComfyUI/custom_nodes/ComfyUI-MMAudio/requirements.txt" ]; then
  python3 -m pip install -q -r "${VOL}/ComfyUI/custom_nodes/ComfyUI-MMAudio/requirements.txt" 2>/dev/null || true
fi
[ -d "${VOL}/ComfyUI/models" ] && ( find "${VOL}/ComfyUI/models" -type f >/dev/null 2>&1 ; log "model metadata prewarm done" ) &
log "setup done — launching ComfyUI"
cd "${COMFY}"
exec env PYTHONPATH="${VOL}/pylibs:${PYTHONPATH:-}" python3 main.py \
     --listen 0.0.0.0 --port 8188 --enable-cors-header \
     --extra-model-paths-config "${COMFY}/extra_model_paths.yaml"
EOS

# 4. Bake model weights for volume-LESS, DC-agnostic deploys (build with --build-arg BAKE_MODELS=1).
#    Reads models.txt ("<dest_rel_path> <url>" lines) and curls each into ${COMFY}/models/<dest>.
ARG BAKE_MODELS=0
COPY models.txt /opt/models.txt
RUN if [ "${BAKE_MODELS}" = "1" ]; then set -eux; \
      while read -r dest url; do \
        [ -z "${dest}" ] && continue; case "${dest}" in \#*) continue;; esac; \
        mkdir -p "$(dirname "${COMFY}/models/${dest}")"; \
        echo "baking ${dest}"; curl -fL --retry 3 -o "${COMFY}/models/${dest}" "${url}"; \
      done < /opt/models.txt; \
      ls -lhR "${COMFY}/models/diffusion_models" "${COMFY}/models/text_encoders" "${COMFY}/models/vae"; \
    else echo "BAKE_MODELS=0 — models read from the network volume at runtime"; fi

EXPOSE 8188
CMD ["/opt/bs_entrypoint.sh"]
