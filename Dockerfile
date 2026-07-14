FROM runpod/comfyui:cuda12.8

ENV COMFY=/workspace/runpod-slim/ComfyUI \
    PIP_NO_CACHE_DIR=1 \
    DEBIAN_FRONTEND=noninteractive

# 1. Bake the custom nodes the face-lock render path needs (WanVideoWrapper) + optional foley (MMAudio).
ARG WANWRAPPER_REF=main
ARG MMAUDIO_REF=main
RUN set -eux; cd "${COMFY}/custom_nodes" && \
    git clone https://github.com/kijai/ComfyUI-WanVideoWrapper.git && \
    ( cd ComfyUI-WanVideoWrapper && git checkout "${WANWRAPPER_REF}" ) && \
    ( git clone https://github.com/kijai/ComfyUI-MMAudio.git && \
      cd ComfyUI-MMAudio && git checkout "${MMAUDIO_REF}" ) || echo "MMAudio optional/skipped"

# 2. Bake ALL pip requirements so a cold pod never has to pip-install at boot.
RUN python3 -m pip install --no-cache-dir \
        gguf diffusers transformers einops accelerate omegaconf easydict ftfy \
        sentencepiece protobuf imageio-ffmpeg av sageattention && \
    ( test -f "${COMFY}/custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt" && \
        python3 -m pip install --no-cache-dir -r "${COMFY}/custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt" || true ) && \
    ( test -f "${COMFY}/custom_nodes/ComfyUI-MMAudio/requirements.txt" && \
        python3 -m pip install --no-cache-dir -r "${COMFY}/custom_nodes/ComfyUI-MMAudio/requirements.txt" || true )

# 3. Entrypoint (written inline so this is the ONLY file the build needs). Models stay on the /wan-vol
#    network volume via extra_model_paths.yaml; a background find/stat pre-warms MooseFS metadata.
RUN cat > /opt/bs_entrypoint.sh <<'EOS' && chmod +x /opt/bs_entrypoint.sh
#!/bin/bash
set -u
COMFY="${COMFY:-/workspace/runpod-slim/ComfyUI}"
VOL="/wan-vol"
log(){ echo "[bs-entrypoint $(date +%H:%M:%S)] $*"; }
T0=$(date +%s)
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
if [ -d "${VOL}/ComfyUI/custom_nodes" ]; then
  for d in "${VOL}/ComfyUI/custom_nodes"/*/; do
    n="$(basename "$d")"
    [ -e "${COMFY}/custom_nodes/$n" ] || ln -sfn "$d" "${COMFY}/custom_nodes/$n"
  done
fi
( find "${VOL}/ComfyUI/models" -type f >/dev/null 2>&1 ; log "model metadata prewarm done" ) &
log "setup done in $(( $(date +%s) - T0 ))s â€” launching ComfyUI"
cd "${COMFY}"
exec env PYTHONPATH="${VOL}/pylibs:${PYTHONPATH:-}" python3 main.py \
     --listen 0.0.0.0 --port 8188 --enable-cors-header \
     --extra-model-paths-config "${COMFY}/extra_model_paths.yaml"
EOS

EXPOSE 8188
CMD ["/opt/bs_entrypoint.sh"]
