# ==============================================================================
# Hog Post-Creation Hook & Vivado GUI Custom Command
# ==============================================================================

# 1. Define the self-contained export command for the GUI button
set export_cmd {
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
            open_bd_design $bd -quiet
            
            # Export to PDF with upright orientation
            if {[catch {write_bd_layout -format pdf -orientation portrait -force $pdf_dest} err_msg]} {
                send_msg_id "Hog-101" "INFO" "PDF export skipped in batch mode. Open Vivado GUI to export."
            } else {
                send_msg_id "Hog-100" "INFO" "Exported Block Design PDF to: $pdf_dest"
            }
        }
    } else {
        send_msg_id "Hog-102" "WARNING" "No Block Design (.bd) found in the open project."
    }
}

# 2. Register the GUI custom command
if {[info commands create_gui_custom_command] ne ""} {
    catch { remove_gui_custom_commands "ExportBDPDF" }

    create_gui_custom_command \
        -name "ExportBDPDF" \
        -menu_name "Export BD to Context PDF" \
        -description "Exports the current Block Design diagram to context/*.pdf" \
        -show_on_toolbar \
        -run_proc false \
        -command $export_cmd

    send_msg_id "Hog-103" "INFO" "Custom GUI button registered: Tools -> Custom Commands -> Export BD to Context PDF"
}

# 3. Try running immediately if project creation happens in GUI mode
catch { eval $export_cmd }