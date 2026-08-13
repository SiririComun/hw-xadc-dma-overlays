# ==============================================================================
# Hog Post-Creation Hook & Vivado GUI Custom Button
# ==============================================================================

# 1. Define the procedure to export the BD layout to context/
proc export_bd_to_context {} {
    # Dynamically find repo root from the active Vivado project directory
    set prj_dir   [get_property DIRECTORY [current_project]]
    set repo_root [file normalize [file join $prj_dir ".." ".."]]
    set dest_dir  [file join $repo_root "context"]

    if {![file exists $dest_dir]} {
        file mkdir $dest_dir
    }

    set bd_files [get_files *.bd]
    if {[llength $bd_files] > 0} {
        foreach bd $bd_files {
            set bd_name [file rootname [file tail $bd]]
            set pdf_dest [file join $dest_dir "${bd_name}.pdf"]
            
            # Ensure the Block Design is open
            open_bd_design $bd
            
            # Export the diagram as a landscape PDF
            write_bd_layout -format pdf -orientation landscape -force $pdf_dest
            
            send_msg_id "Hog-PDF" "INFO" "Exported Block Design PDF to: $pdf_dest"
        }
    } else {
        send_msg_id "Hog-PDF" "WARNING" "No Block Design (.bd) found in the open project."
    }
}

# 2. Execute automatically during project creation
export_bd_to_context

# 3. Register a GUI Custom Button & Menu Item in the Vivado IDE
if {[info exists ::env(DISPLAY)] || [get_param -quiet gui.displayMode] ne ""} {
    # Remove old instance if it exists to avoid duplication
    remove_gui_custom_commands -quiet "ExportBDPDF"

    create_gui_custom_command \
        -name "ExportBDPDF" \
        -menu_name "Export BD to Context PDF" \
        -description "Exports the current Block Design diagram to context/*.pdf" \
        -show_on_toolbar \
        -run_proc true \
        -command "export_bd_to_context"

    send_msg_id "Hog-PDF" "INFO" "Custom GUI button registered: Tools -> Custom Commands -> Export BD to Context PDF"
}