# ==============================================================================
# Hog Post-Creation Hook & Vivado GUI Custom Commands (PDF & SVG Exporters)
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Command: Export BD to context/*.pdf
# ------------------------------------------------------------------------------
set export_pdf_cmd {
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
            
            open_bd_design $bd -quiet
            
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

# ------------------------------------------------------------------------------
# 2. Command: Export BD to docs/images/*_bd.svg
# ------------------------------------------------------------------------------
set export_svg_cmd {
    set prj_dir   [get_property DIRECTORY [current_project]]
    set repo_root [file normalize [file join $prj_dir ".." ".."]]
    set dest_dir  [file join $repo_root "docs" "images"]

    if {![file exists $dest_dir]} {
        file mkdir $dest_dir
    }

    set bd_files [get_files *.bd]
    if {[llength $bd_files] > 0} {
        foreach bd $bd_files {
            set bd_name [file rootname [file tail $bd]]
            set svg_dest [file join $dest_dir "${bd_name}_bd.svg"]
            
            open_bd_design $bd -quiet
            
            if {[catch {write_bd_layout -format svg -force $svg_dest} err_msg]} {
                send_msg_id "Hog-105" "INFO" "SVG export skipped in batch mode. Open Vivado GUI to export."
            } else {
                send_msg_id "Hog-104" "INFO" "Exported Block Design SVG to: $svg_dest"
            }
        }
    } else {
        send_msg_id "Hog-102" "WARNING" "No Block Design (.bd) found in the open project."
    }
}

# ------------------------------------------------------------------------------
# 3. Register GUI Custom Commands on the Vivado Toolbar
# ------------------------------------------------------------------------------
if {[info commands create_gui_custom_command] ne ""} {
    # PDF Button
    catch { remove_gui_custom_commands "ExportBDPDF" }
    create_gui_custom_command \
        -name "ExportBDPDF" \
        -menu_name "Export BD to Context PDF" \
        -description "Exports the current Block Design diagram to context/*.pdf" \
        -show_on_toolbar \
        -run_proc false \
        -command $export_pdf_cmd

    # SVG Button
    catch { remove_gui_custom_commands "ExportBDSVG" }
    create_gui_custom_command \
        -name "ExportBDSVG" \
        -menu_name "Export BD to Docs SVG" \
        -description "Exports the current Block Design diagram to docs/images/*_bd.svg" \
        -show_on_toolbar \
        -run_proc false \
        -command $export_svg_cmd

    send_msg_id "Hog-103" "INFO" "Custom GUI buttons registered: Tools -> Custom Commands -> Export BD to Context PDF / Docs SVG"
}

# ------------------------------------------------------------------------------
# 4. Run immediately on project open if in GUI mode
# ------------------------------------------------------------------------------
catch { eval $export_pdf_cmd }
catch { eval $export_svg_cmd }