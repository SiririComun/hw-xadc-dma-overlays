#!/usr/bin/env bash
# ==============================================================================
# Script: context/generate_hw_summary.sh
# Target: hw-xadc-dma-overlays
# Purpose: Dump Git history, structure, and exact HW files into context/hw_summary.txt
# ==============================================================================

# Dynamically locate context directory and repository root
CONTEXT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${CONTEXT_DIR}/.." && pwd)"
OUTPUT_FILE="${CONTEXT_DIR}/hw_summary.txt"

echo "Generating concise HW summary into: ${OUTPUT_FILE}..."
> "${OUTPUT_FILE}"

cd "${REPO_ROOT}" || exit 1

# 1. Header, Branch Status & Git History
cat << 'EOF' >> "${OUTPUT_FILE}"
Git Context & Branch Info:

```log
EOF

if command -v git &> /dev/null && git rev-parse --is-inside-work-tree &> /dev/null; then
    echo "Current Branch: $(git branch --show-current)" >> "${OUTPUT_FILE}"
    echo "Branch Tracking Status:" >> "${OUTPUT_FILE}"
    git branch -vv >> "${OUTPUT_FILE}"
    echo "" >> "${OUTPUT_FILE}"
    echo "Git Commit Graph & History:" >> "${OUTPUT_FILE}"
    git log --graph --pretty=format:"%h %d - %cd : %s (%an)" --date=short -n 15 >> "${OUTPUT_FILE}"
fi

cat << 'EOF' >> "${OUTPUT_FILE}"
```

EOF

# 3. Exact list of targeted files and their markdown syntax
TARGET_FILES=(
    ".github/workflows/release.yml:yaml"
    "Top/pynq_z2/hog.conf:conf"
    "Top/pynq_z2/post-creation.tcl:tcl"
    "Top/pynq_z2/post-bitstream.tcl:tcl"
    "Top/pynq_z2/list/ips.src:src"
    "Top/pynq_z2/list/others.src:src"
    "Top/pynq_z2/list/xil_defaultlib.src:src"
    "Top/pynq_z2/list/constrs.src:src"
    "src/bd/xadc.bd:bd"
    "src/hdl/tlast_generator.vhd:vhd"
    "src/hdl/xadc_wrapper.vhd:vhd"
    "src/hdl/axis_trigger_unit.vhd:vhd"
    "src/hdl/axis_decimator.vhd:vhd"
    "src/hdl/axis_channel_demux.vhd:vhd"
    "src/hdl/axis_spectral_mask.vhd:vhd"
    "src/con/pynq_z2.xdc:xdc"
    "context/generate_hw_summary.sh:bash"
)

# 4. Append each file
for item in "${TARGET_FILES[@]}"; do
    filepath="${item%%:*}"
    syntax="${item##*:}"
    filename=$(basename "$filepath")

    if [ -f "$filepath" ]; then
        echo "Adding: ${filepath}"
        {
            echo "${filename}:"
            echo ""
            echo "\`\`\`${syntax}"
            cat "${filepath}"
            echo "\`\`\`"
            echo ""
        } >> "${OUTPUT_FILE}"
    else
        echo "Warning: File not found -> ${filepath}"
    fi
done

echo "Done! HW context generated in: ${OUTPUT_FILE}"
