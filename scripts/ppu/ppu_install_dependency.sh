#!/bin/bash
# ==============================================================================
# scripts/ppu/ppu_install_dependency.sh — PPU CI 依赖安装（GitHub Actions）
# ------------------------------------------------------------------------------
# 调用方：PR CI 的 attention、samplers、benchmarks，在 PPU Pod 中执行。
# 先安装本次 CI 构建的 wheel，其余 PPU 栈优先使用镜像预装组件。
#
# 核心原则（sglang 踩坑经验，见其脚本注释）：镜像预装的 PPU 栈（带
# +v0.x.0.ppu2.2.0 local version 的 torch/vllm/triton/flashinfer 等）一律
# 不动——blind `--force-reinstall` 会用同版本号的另一种构建覆盖镜像里的
# 版本，甚至降级。只安装镜像里真正缺失的包。
# ==============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

# --retries/--timeout：pip 默认只重试 5 次且无连接超时上限，显式收紧后
# 单次调用不会在网络挂起时耗满 job timeout。
PIP_INSTALL="python3 -m pip install --no-cache-dir --retries 5 --timeout 30"
# SAIL SDK v2.2.0 PyPI source
PPU_PIP_INDEX="https://pkg.flytiger-eco.com/artifactory/api/pypi/pypi_index/simple"

# 从私有 index 装包统一走这里。
# 为什么在 pip --retries 之外再包一层：pip 的重试只覆盖连接层错误，索引
# 返回空版本列表（"ERROR: ... (from versions: none)"）属应用层结果，pip
# 视为确定性失败、不重试，而这恰好是并发拉包时的表现。
# 实测依据：
# - 2026-09-09：4 个 area 并发起 Pod 时全部卡在 pytest 工具链安装，报
#   pytest-asyncio from versions: none；当时索引页直连正常，按瞬时故障处理。
# - 2026-09-10（run 34440797915）：故障升级为分钟级——benchmarks/pytorch/cuda
#   的 pytest-asyncio 空页持续 ≥5min，旧窗口（4 次 × ~35s ≈ 2min）盖不住，
#   三个 area 全灭（老 area models-basic/samplers/kernels 同款）。故窗口拉长到
#   ~10min，并加 NAS wheelhouse 兜底。
# NAS wheelhouse（--find-links 常挂）：mirror 空页时 pip 仍能从 NAS 的 wheel
# 解析出版本，不等重试直接免疫；装成功后顺手回写（自愈播种）。目录不存在
# 则自动跳过，无硬依赖。首次播种（任一可写 NAS 的机器执行一次）：
#   mkdir -p /nas_aisw/devops/pip-wheelhouse && \
#   python3 -m pip download --no-deps pytest pytest-asyncio tblib \
#     pytest-shard pyyaml -d /nas_aisw/devops/pip-wheelhouse \
#     -i https://pkg.flytiger-eco.com/artifactory/api/pypi/pypi_index/simple
# 退避带随机抖动：并发 Pod 若同步重试会再次撞在一起。
PPU_WHEELHOUSE="${PPU_WHEELHOUSE:-/nas_aisw/devops/pip-wheelhouse}"
# build-wheel job 在出网正常的云 runner 上预下载的测试 toolchain wheel，随
# ci-wheel/ 打进源码 tarball 送进 Pod。命中即完全免网——既躲开 mirror 空页，
# 也躲开 Pod 出网代理（ptg-green-proxy）抖动。目录不存在（本地调用未传入
# wheel，或云端预下载失败）则自动跳过离线优先、直接走索引，行为不变。
PPU_TOOLCHAIN_DIR="${PPU_TOOLCHAIN_DIR:-/workspace/source/ci-wheel/toolchain}"
_pip_retry() {
    local max=8 n=1 wait_s
    local wh_args=()
    if [[ -d "${PPU_WHEELHOUSE}" ]]; then
        wh_args=(--find-links "${PPU_WHEELHOUSE}")
    fi
    # 离线优先：先用 --no-index 从本地 toolchain 目录装，成功即返回（无网络、
    # 无自愈回写）。仅当本次请求的包能被离线解析时成功；否则（如 vllm 等不在
    # toolchain 里）pip 立即失败（--no-index 不触网），落到下方索引重试循环。
    if [[ -d "${PPU_TOOLCHAIN_DIR}" ]] && compgen -G "${PPU_TOOLCHAIN_DIR}/*.whl" > /dev/null 2>&1; then
        # shellcheck disable=SC2068  # $@ 需按词拆分成 pip 参数（含 --no-deps 等）
        if ${PIP_INSTALL} $@ --no-index --find-links "${PPU_TOOLCHAIN_DIR}"; then
            echo "[deps] installed offline from ${PPU_TOOLCHAIN_DIR}: $*"
            return 0
        fi
        echo "[deps] offline toolchain miss, fall back to index: $*" >&2
    fi
    while true; do
        # shellcheck disable=SC2068  # $@ 需按词拆分成 pip 参数（含 --no-deps 等）
        if ${PIP_INSTALL} $@ -i "${PPU_PIP_INDEX}" "${wh_args[@]}"; then
            # 自愈回写（best-effort，失败不影响主流程）：装成功的包沉淀到
            # wheelhouse，供后续 mirror 空页时 --find-links 命中
            if [[ -d "${PPU_WHEELHOUSE}" ]] && touch "${PPU_WHEELHOUSE}/.rw_probe" 2>/dev/null; then
                rm -f "${PPU_WHEELHOUSE}/.rw_probe"
                local pkgs=() a
                for a in "$@"; do [[ "${a}" == -* ]] || pkgs+=("${a}"); done
                python3 -m pip download --no-cache-dir --no-deps -q \
                    "${pkgs[@]}" -d "${PPU_WHEELHOUSE}" -i "${PPU_PIP_INDEX}" \
                    2>/dev/null || true
            fi
            return 0
        fi
        if [[ ${n} -ge ${max} ]]; then
            echo "[deps] ERROR: pip install failed after ${max} attempts: $*" >&2
            return 1
        fi
        wait_s=$(( n * 30 > 90 ? 90 : n * 30 ))
        wait_s=$(( wait_s + RANDOM % 30 ))
        echo "[deps] pip install failed (attempt ${n}/${max}), retry in ${wait_s}s: $*" >&2
        sleep "${wait_s}"
        n=$(( n + 1 ))
    done
}

# flytiger artifactory 凭证（GitHub Secrets 注入；镜像公开时可无）
if [[ -n "${PPU_ARTIFACTORY_USER:-}" && -n "${PPU_ARTIFACTORY_PASSWORD:-}" ]]; then
    echo "machine pkg.flytiger-eco.com login ${PPU_ARTIFACTORY_USER} password ${PPU_ARTIFACTORY_PASSWORD}" > ~/.netrc
    chmod 600 ~/.netrc
fi

# 容器内以 root 运行 git 需要（vllm 版本号由 setuptools-scm 从 git 推导时也依赖它）
git config --global --add safe.directory "${REPO_ROOT}"

# ------------------------------------------------------------------------------
# [wheel] 安装构建的wheel
# ------------------------------------------------------------------------------
# PR CI 总是传入本次 wheel；本地调用未传入时保留镜像预装版本。
if [[ -n "${PPU_WHEEL_PATH:-}" ]]; then
    if [[ ! -f "${PPU_WHEEL_PATH}" ]]; then
        echo "[wheel] ERROR: PPU_WHEEL_PATH set but not found: ${PPU_WHEEL_PATH}" >&2
        exit 1
    fi
    echo "========== [wheel] install CI-built wheel =========="
    echo "[wheel] ${PPU_WHEEL_PATH}"
    ${PIP_INSTALL} --force-reinstall --no-deps "${PPU_WHEEL_PATH}"
fi

# ------------------------------------------------------------------------------
# [diag] 环境盘点：先看清镜像里已有什么，再决定装什么
# ------------------------------------------------------------------------------
echo "========== [diag] preinstalled stack =========="
python3 -c "import torch; print('torch', torch.__version__, 'device_count', torch.cuda.device_count())"
python3 -c "import vllm; print('vllm', vllm.__version__)" || echo "vllm NOT importable"
python3 -m pip list 2>/dev/null | grep -iE "^(vllm|torch|triton|flashinfer|deep.ep|deep.gemm|tilelang|flash.mla|flash.attn|transformers) " || true

# ------------------------------------------------------------------------------
# [deps] PPU 依赖：镜像预装优先，缺失才从 flytiger PyPI 补
# ------------------------------------------------------------------------------
# area 先安装 CI 现编的 v0.26.0 wheel；未传 wheel 时沿用 SDK 2.2 镜像预装
# 的 v0.27.0。其余组件版本沿用现有 PPU CI 配置，仅在镜像缺包时兜底。
# 版本与下表不同（通常更新），以镜像为准，不降级。
_ensure_pip_pkg() {
    local pkg="$1" ver="$2" extra_args="${3:-}"
    local installed
    installed="$(python3 -c "import importlib.metadata as m; print(m.version('${pkg}'))" 2>/dev/null || true)"
    if [[ -n "${installed}" ]]; then
        echo "[deps] ${pkg} already installed: ${installed} — keep image build"
        return 0
    fi
    echo "[deps] installing ${pkg}==${ver}"
    # shellcheck disable=SC2086  # extra_args is intentionally word-split
    _pip_retry "${pkg}==${ver}" ${extra_args}
}

# vllm 本体：不带 --no-deps（需解析依赖树）；其余 PPU 组件按指南 --no-deps
_ensure_pip_pkg "vllm" "0.26.0"
_ensure_pip_pkg "flashinfer_python" "0.6.8.post1" "--no-deps --force-reinstall"
_ensure_pip_pkg "deep_ep" "1.0.0" "--no-deps --force-reinstall"
_ensure_pip_pkg "deep_gemm" "1.0.0" "--no-deps --force-reinstall"
_ensure_pip_pkg "tilelang" "0.1.8" "--no-deps --force-reinstall"
_ensure_pip_pkg "flash_mla" "2.0.0" "--no-deps --force-reinstall"
_ensure_pip_pkg "flash_attn_3" "2.8.2" "--no-deps --force-reinstall"
_ensure_pip_pkg "flash_attn" "2.7.4.post1" "--no-deps --force-reinstall"

# ------------------------------------------------------------------------------
# [deps] pytest 测试依赖
# ------------------------------------------------------------------------------
# pytest-asyncio: tests/conftest.py asyncio fixture 需要
# tblib: pytest 跨进程 traceback 序列化（spawn worker 报错时）
# pytest-shard: single 模式 --shard-id/--num-shards 需要
# pyyaml: 测试工具链通用依赖
echo "========== [deps] pytest toolchain =========="
_pip_retry pytest pytest-asyncio tblib pytest-shard pyyaml

# ------------------------------------------------------------------------------
# [cext] 将已安装 wheel 的编译产物复制到源码树，供 pytest 导入。
# ------------------------------------------------------------------------------
# pytest 从源码树导入 vllm，因此需补齐本次 wheel 的扩展和版本信息。
# 使用 sysconfig 定位 site-packages，避免 import vllm 错指向源码树。
echo "========== [cext] 复制已安装 wheel 的编译产物 =========="
SP_SITE="$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
SP_VLLM_DIR="${SP_SITE}/vllm"
if [ ! -d "${SP_VLLM_DIR}" ]; then
    echo "[cext] ERROR: 已安装的 vllm not found at ${SP_VLLM_DIR}" >&2
    exit 1
fi
cext_copied=0
# 递归复制已安装 vllm 包内所有编译产物并保持相对路径：顶层
# _C_stable_libtorch/_moe_C_stable_libtorch/... 之外，
# vllm_flash_attn/ 子目录里还有 _vllm_fa2_C/_vllm_fa3_C（FA2/FA3 可用性探针，
# vllm/vllm_flash_attn/__init__.py 缺少它们会直接 raise ImportError）。
# 用 find 全量复制而非按文件名枚举：wheel 增减扩展时本脚本无需同步改动。
while IFS= read -r f; do
    rel="${f#"${SP_VLLM_DIR}"/}"
    dest="${REPO_ROOT}/vllm/${rel}"
    mkdir -p "$(dirname "${dest}")"
    cp -f "$f" "${dest}"
    echo "[cext] copied vllm/${rel}"
    cext_copied=1
done < <(find "${SP_VLLM_DIR}" -maxdepth 3 -type f -name '*.so')
if [ -f "${SP_VLLM_DIR}/_version.py" ]; then
    cp -f "${SP_VLLM_DIR}/_version.py" "${REPO_ROOT}/vllm/"
    echo "[cext] copied vllm/_version.py"
    cext_copied=1
fi
# auditwheel 打包的 wheel 会把依赖库放 vllm.libs/，RPATH 指向 $ORIGIN/../vllm.libs
if [ -d "${SP_VLLM_DIR}.libs" ]; then
    cp -rf "${SP_VLLM_DIR}.libs" "${REPO_ROOT}/"
    echo "[cext] copied vllm.libs/"
    cext_copied=1
fi
# ------------------------------------------------------------------------------
# [cext] 同步已安装 wheel 中的 PPU flash attention 适配。
# ------------------------------------------------------------------------------
# PR 安装的 wheel 与当前源码来自同一次构建，不从旧镜像覆盖源码改动。
FA_DIR_SRC="${SP_VLLM_DIR}/vllm_flash_attn"
if [ ! -d "${FA_DIR_SRC}" ]; then
    echo "[cext] ERROR: no vllm_flash_attn dir in 已安装的 vllm package" >&2
    exit 1
fi
echo "[cext] 已安装的 vllm_flash_attn contents:"
ls -l "${FA_DIR_SRC}"
# .so 已由上面的 find 循环同步进源码树，此 diff 实际反映 .py 层面的差异
if ! diff -rq --exclude=__pycache__ "${FA_DIR_SRC}" "${REPO_ROOT}/vllm/vllm_flash_attn" >/dev/null 2>&1; then
    echo "[cext] 已安装 wheel 与源码树不同，复制 wheel 中的适配目录："
    diff -rq --exclude=__pycache__ "${FA_DIR_SRC}" "${REPO_ROOT}/vllm/vllm_flash_attn" || true
    cp -rf "${FA_DIR_SRC}/." "${REPO_ROOT}/vllm/vllm_flash_attn/"
    rm -rf "${REPO_ROOT}/vllm/vllm_flash_attn/__pycache__"
    echo "[cext] copied vllm/vllm_flash_attn/ (已安装 wheel 版本)"
else
    echo "[cext] 已安装的 vllm_flash_attn identical to source tree — nothing to borrow;"
    echo "[cext] upstream probe will raise without _vllm_fa2_C/_vllm_fa3_C (see verify step)"
fi
if [ "${cext_copied}" -eq 0 ]; then
    echo "[cext] ERROR: no compiled extensions found in ${SP_VLLM_DIR}" >&2
    exit 1
fi
# 对症验证：v0.26.0 CUDA/PPU 路径使用 vllm._C_stable_libtorch；legacy
# vllm._C 仅由 ROCm 构建，不应作为 PPU wheel 的必需扩展。
python3 -c "import vllm._C_stable_libtorch as c; print('[cext] vllm._C_stable_libtorch OK from source tree:', c.__file__)"
# 对症验证：同步本次 wheel 的 PPU 适配后 import 不应再 raise
python3 -c "import vllm.vllm_flash_attn as fa; print('[cext] vllm.vllm_flash_attn OK: FA2=%s FA3=%s' % (fa.FA2_AVAILABLE, fa.FA3_AVAILABLE))"

echo "========== [verify] final stack =========="
python3 -c "import torch; print('torch', torch.__version__, 'device_count', torch.cuda.device_count())"
# 混合形态下 __version__ 来自已安装 wheel 的 _version.py（0.26.0+…），
# 不再是源码树的 'dev' fallback —— 这本身就是 [cext] 生效的信号
python3 -c "import vllm; print('vllm', vllm.__version__)"
echo "[deps] done"
