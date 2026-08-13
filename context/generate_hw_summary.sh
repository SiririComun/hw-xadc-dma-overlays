#!/usr/bin/env bash
# ==============================================================================
# Script: context/generate_hw_summary.sh
# Target: hw-xadc-dma-overlays
# Purpose: Dump ONLY the exact HW files and structure into context/hw_summary.txt
# ==============================================================================

# Dynamically locate the context directory and repository root
CONTEXT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${CONTEXT_DIR}/.." && pwd)"
OUTPUT_FILE="${CONTEXT_DIR}/hw_summary.txt"

echo "Generating concise HW summary into: ${OUTPUT_FILE}..."
> "${OUTPUT_FILE}"

# Change execution context to repository root so all relative paths remain consistent
cd "${REPO_ROOT}" || exit 1

# 1. Header & Directory Tree
cat << 'EOF' >> "${OUTPUT_FILE}"
hw repository context:

Files structure: 

```log
EOF

# Tree output matching your clean structure
if command -v tree &> /dev/null; then
    tree -I '.git|Projects|Hog|.Xil|*.runs|*.gen|*.cache|*.hw|*.ip_user_files|ip|ipshared|sim|synth|hw_handoff' >> "${OUTPUT_FILE}"
fi

cat << 'EOF' >> "${OUTPUT_FILE}"
```

EOF

# 2. Exact list of targeted files and their markdown syntax
TARGET_FILES=(
    "Top/pynq_z2/hog.conf:conf"
    "Top/pynq_z2/post-bitstream.tcl:tcl"
    "Top/pynq_z2/list/ips.src:src"
    "Top/pynq_z2/list/others.src:src"
    "Top/pynq_z2/list/xil_defaultlib.src:src"
    "src/bd/xadc.bd:bd"
    "src/hdl/tlast_generator.vhd:vhd"
    "src/hdl/xadc_wrapper.vhd:vhd"
    "context/generate_hw_summary.sh"
)

# 3. Append each file in the exact format
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

echo "Done! Summary generated in: ${OUTPUT_FILE}"