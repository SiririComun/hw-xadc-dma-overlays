# ==============================================================================
# Hog Post-Bitstream Hook: Automated PYNQ Handoff File Copier [1.5]
# ==============================================================================

# Get the directory of this script (Top/xadc/)
set script_path [file normalize [info script]]
set script_dir [file dirname $script_path]

# Navigate up two levels to resolve the repository root directory [1.5]
set repo_root [file normalize [file join $script_dir ".." ".."]]

# Define source paths of Vivado output products
set bit_src  [file join $repo_root "Projects" "xadc" "xadc.runs" "impl_1" "xadc_wrapper.bit"]
set hwh_src  [file join $repo_root "Projects" "xadc" "xadc.gen" "sources_1" "bd" "xadc" "hw_handoff" "xadc.hwh"]

# Define target destination directory inside your PYNQ Python package [1.5]
set dest_dir [file join $repo_root "python_package" "src" "pynq_ad3_xadc" "overlays"]

# Ensure the destination directory exists [1.5]
if {![file exists $dest_dir]} {
    file mkdir $dest_dir
}

# Define target renamed filenames for PYNQ compatibility [1.5]
set bit_dest [file join $dest_dir "xadc.bit"]
set hwh_dest [file join $dest_dir "xadc.hwh"]

# Copy and rename the compiled bitstream (.bit)
if {[file exists $bit_src]} {
    file copy -force $bit_src $bit_dest
    send_msg_id "Hog:PostBitstream" "INFO" "Successfully copied compiled bitstream to: $bit_dest"
} else {
    send_msg_id "Hog:PostBitstream" "ERROR" "Could not find source bitstream at: $bit_src"
}

# Copy and rename the hardware handoff metadata (.hwh)
if {[file exists $hwh_src]} {
    file copy -force $hwh_src $hwh_dest
    send_msg_id "Hog:PostBitstream" "INFO" "Successfully copied hardware handoff metadata to: $hwh_dest"
} else {
    send_msg_id "Hog:PostBitstream" "ERROR" "Could not find source hardware handoff metadata at: $hwh_src"
}
