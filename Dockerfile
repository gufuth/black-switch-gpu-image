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

# 2. Bake EXACTLY the deps our proven per-boot bring_up installs â€” no more, no less. This is the whole
#    point of the image: a cold pod never pip-installs the render dependencies again. Deliberately NO
#    sageattention (the render was validated on the sdpa baseline; sage was reverted as no-win). The
#    constraint file + a final `pip check` guard against any silent numpy/torch drift.
RUN python3 -m pip install --no-cache-dir \
        gguf diffusers transformers einops accelerate omegaconf easydict ftfy \
        sentencepiece protobuf imageio-ffmpeg av && \
    python3 -m pip check || echo "WARN: pip check reported issues (non-fatal; inspect build log)"

# 3. Entrypoint (inline â€” the ONLY file the build produces besides deps). We deliberately DO NOT bake
#    custom nodes: the entrypoint symlinks the volume's EXACT, already-validated node versions
#    (WanVideoWrapper etc.), so there is ZERO version drift. The baked deps above cover their imports;
#    only the optional MMAudio foley node still pip-installs at boot, and only if present (guarded).
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
# Symlink the volume's EXACT custom nodes (unconditionally, exactly like the proven bring_up) so the
# render runs the same node versions the models + graph were validated against.
if [ -d "${VOL}/ComfyUI/custom_nodes" ]; then
  for d in "${VOL}/ComfyUI/custom_nodes"/*/; do
    n="$(basename "$d")"; ln -sfn "$d" "${COMFY}/custom_nodes/$n"
  done
fi
# Optional foley node reqs (guarded; only if the node is on the volume). Normal renders never hit this.
if [ -f "${VOL}/ComfyUI/custom_nodes/ComfyUI-MMAudio/requirements.txt" ]; then
  python3 -m pip install -q -r "${VOL}/ComfyUI/custom_nodes/ComfyUI-MMAudio/requirements.txt" 2>/dev/null || true
fi
( find "${VOL}/ComfyUI/models" -type f >/dev/null 2>&1 ; log "model metadata prewarm done" ) &
log "setup done â€” launching ComfyUI"
cd "${COMFY}"
exec env PYTHONPATH="${VOL}/pylibs:${PYTHONPATH:-}" python3 main.py \
     --listen 0.0.0.0 --port 8188 --enable-cors-header \
     --extra-model-paths-config "${COMFY}/extra_model_paths.yaml"
EOS

EXPOSE 8188
CMD ["/opt/bs_entrypoint.sh"]
