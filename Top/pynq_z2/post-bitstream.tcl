# ==============================================================================
# Hog Post-Bitstream Hook: Automated PYNQ Handoff File Copier
# ==============================================================================

# Get project directory name dynamically (evaluates to "pynq_z2")
set script_path [file normalize [info script]]
set script_dir  [file dirname $script_path]
set prj_name    [file tail $script_dir]
set repo_root   [file normalize [file join $script_dir ".." ".."]]

# Source path matches Vivado's dynamic build output folder
set bit_src [file join $repo_root "Projects" $prj_name "${prj_name}.runs" "impl_1" "xadc_wrapper.bit"]

# Try generated HW handoff location
set hwh_src [file join $repo_root "src" "bd" "hw_handoff" "xadc.hwh"]
if {![file exists $hwh_src]} {
    set hwh_src [file join $repo_root "Projects" $prj_name "${prj_name}.gen" "sources_1" "bd" "xadc" "hw_handoff" "xadc.hwh"]
}

set dest_dir [file join $repo_root "bin"]
if {![file exists $dest_dir]} {
    file mkdir $dest_dir
}

set bit_dest [file join $dest_dir "${prj_name}.bit"]
set hwh_dest [file join $dest_dir "${prj_name}.hwh"]

# Copy Bitstream
if {[file exists $bit_src]} {
    file copy -force $bit_src $bit_dest
    send_msg_id "Hog-1" "INFO" "Successfully copied compiled bitstream to: $bit_dest"
} else {
    send_msg_id "Hog-2" "ERROR" "Could not find source bitstream at: $bit_src"
}

# Copy Hardware Handoff
if {[file exists $hwh_src]} {
    file copy -force $hwh_src $hwh_dest
    send_msg_id "Hog-3" "INFO" "Successfully copied hardware handoff metadata to: $hwh_dest"
} else {
    send_msg_id "Hog-4" "ERROR" "Could not find source hardware handoff metadata at: $hwh_src"
}
