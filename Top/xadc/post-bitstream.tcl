# ==============================================================================
# Hog Post-Bitstream Hook: Automated PYNQ Handoff File Copier
# ==============================================================================

# Get the directory of this script (Top/xadc/)
set script_path [file normalize [info script]]
set script_dir [file dirname $script_path]

# Navigate up two levels to resolve the repository root directory
set repo_root [file normalize [file join $script_dir ".." ".."]]

# Define source paths of Vivado output products
set bit_src  [file join $repo_root "Projects" "xadc" "xadc.runs" "impl_1" "xadc_wrapper.bit"]
# CORRECTED: Point to the actual generated location in the source directory
set hwh_src  [file join $repo_root "src" "bd" "hw_handoff" "xadc.hwh"]

# Define target destination directory inside your PYNQ Python package
set dest_dir [file join $repo_root "bin"]

# Ensure the destination directory exists
if {![file exists $dest_dir]} {
    file mkdir $dest_dir
}

# Define target renamed filenames for PYNQ compatibility
set bit_dest [file join $dest_dir "xadc.bit"]
set hwh_dest [file join $dest_dir "xadc.hwh"]

# Copy and rename the compiled bitstream (.bit)
if {[file exists $bit_src]} {
    file copy -force $bit_src $bit_dest
    send_msg_id "Hog-1" "INFO" "Successfully copied compiled bitstream to: $bit_dest"
} else {
    send_msg_id "Hog-2" "ERROR" "Could not find source bitstream at: $bit_src"
}

# Copy and rename the hardware handoff metadata (.hwh)
if {[file exists $hwh_src]} {
    file copy -force $hwh_src $hwh_dest
    send_msg_id "Hog-3" "INFO" "Successfully copied hardware handoff metadata to: $hwh_dest"
} else {
    send_msg_id "Hog-4" "ERROR" "Could not find source hardware handoff metadata at: $hwh_src"
}
