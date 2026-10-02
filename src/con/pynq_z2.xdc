# ==============================================================================
# Physical Package Pin Constraints for PYNQ-Z2 Analog & Digital Headers
# ==============================================================================
# Arduino Header A0 (Vaux1)
set_property -dict { PACKAGE_PIN E17 } [get_ports Vaux1_0_v_p]
set_property -dict { PACKAGE_PIN D18 } [get_ports Vaux1_0_v_n]

# Arduino Header A1 (Vaux9)
set_property -dict { PACKAGE_PIN E18 } [get_ports Vaux9_0_v_p]
set_property -dict { PACKAGE_PIN E19 } [get_ports Vaux9_0_v_n]

# Arduino Header Digital Pin AR2 (Buzzer Pulse Trigger Output)
set_property -dict { PACKAGE_PIN U13   IOSTANDARD LVCMOS33 } [get_ports buzzer_pulse_out]