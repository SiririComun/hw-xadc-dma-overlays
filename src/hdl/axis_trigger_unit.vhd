-- =============================================================================
-- File: axis_trigger_unit.vhd
-- Description: Central Acquisition, Edge Trigger & Hardware ToA/TDOA Controller.
--              Hosts AXI4-Lite registers to dynamically control:
--                • Hardware Edge/Level Triggering (A0 vs A1)
--                • FFT Input Channel Stream Selection (A0 vs A1 via Bit 6)
--                • Hardware Active Buzzer Pulse Generation (Pin buzzer_pulse_out)
--                • Hardware-Accelerated 100 MHz ToA / TDOA Cycle-Accurate Counters
--                • Quasi-Anechoic Direct-Path Energy Accumulation (Registers 0x34, 0x38, 0x3C)
--                • Decimation Ratio (M = 1, 10, 20, 50)
--                • LogiCORE FFT Transform Length (NFFT = 512, 1024, 2048)
--                • TLAST Packet Size (512, 1024, 2048)
--                • Persistent AXI4-Stream Handshake on m_axis_fft_config
-- =============================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity axis_trigger_unit is
    generic (
        C_S_AXI_DATA_WIDTH : integer := 32;
        C_S_AXI_ADDR_WIDTH : integer := 6   -- Decodes addresses 0x00 to 0x3C
    );
    port (
        aclk                     : in  std_logic;
        aresetn                  : in  std_logic;

        -- =====================================================================
        -- AXI4-Lite Slave Interface (Control & Status Registers)
        -- =====================================================================
        s_axi_awaddr             : in  std_logic_vector(C_S_AXI_ADDR_WIDTH - 1 downto 0);
        s_axi_awprot             : in  std_logic_vector(2 downto 0);
        s_axi_awvalid            : in  std_logic;
        s_axi_awready            : out std_logic;
        s_axi_wdata              : in  std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
        s_axi_wstrb              : in  std_logic_vector((C_S_AXI_DATA_WIDTH / 8) - 1 downto 0);
        s_axi_wvalid             : in  std_logic;
        s_axi_wready             : out std_logic;
        s_axi_bresp              : out std_logic_vector(1 downto 0);
        s_axi_bvalid             : out std_logic;
        s_axi_bready             : in  std_logic;
        s_axi_araddr             : in  std_logic_vector(C_S_AXI_ADDR_WIDTH - 1 downto 0);
        s_axi_arprot             : in  std_logic_vector(2 downto 0);
        s_axi_arvalid            : in  std_logic;
        s_axi_arready            : out std_logic;
        s_axi_rdata              : out std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
        s_axi_rresp              : out std_logic_vector(1 downto 0);
        s_axi_rvalid             : out std_logic;
        s_axi_rready             : in  std_logic;

        -- =====================================================================
        -- Hardware Channel Identifier from XADC (0x11 = Vaux1/A0, 0x19 = Vaux9/A1)
        -- =====================================================================
        channel_id               : in  std_logic_vector(4 downto 0);

        -- =====================================================================
        -- AXI4-Stream Slave Interface (Raw Samples from XADC)
        -- =====================================================================
        s_axis_tdata             : in  std_logic_vector(15 downto 0);
        s_axis_tvalid            : in  std_logic;
        s_axis_tready            : out std_logic;

        -- =====================================================================
        -- AXI4-Stream Master Interface (Trigger-Gated Stream to Decimator)
        -- =====================================================================
        m_axis_tdata             : out std_logic_vector(15 downto 0);
        m_axis_tvalid            : out std_logic;
        m_axis_tready            : in  std_logic;

        -- =====================================================================
        -- Frame Feedback (Connected to tlast_generator's m_axis_tlast)
        -- =====================================================================
        frame_done               : in  std_logic;

        -- =====================================================================
        -- Hardware Buzzer Pulse Output (Routes to Arduino AR2 / Pin U13)
        -- =====================================================================
        buzzer_pulse_out         : out std_logic;

        -- =====================================================================
        -- Runtime Configuration Outputs
        -- =====================================================================
        decim_factor_out         : out std_logic_vector(1 downto 0);
        m_axis_fft_config_tdata  : out std_logic_vector(15 downto 0);
        m_axis_fft_config_tvalid : out std_logic;
        m_axis_fft_config_tready : in  std_logic;
        packet_size_out          : out std_logic_vector(15 downto 0);
        fft_chan_sel_out         : out std_logic
    );
end axis_trigger_unit;

architecture Behavioral of axis_trigger_unit is

    -- Constant Channel Addresses in 7-Series XADC
    constant CH_VAUX1            : std_logic_vector(4 downto 0) := "10001"; -- 0x11 (Channel 1 / A0)
    constant CH_VAUX9            : std_logic_vector(4 downto 0) := "11001"; -- 0x19 (Channel 2 / A1)

    -- Maximum ToA wait timeout: 5,000,000 cycles @ 100 MHz = 50.0 ms (sound travels ~17.1 meters)
    constant TOA_TIMEOUT_CYCLES  : unsigned(31 downto 0) := to_unsigned(5000000, 32);

    -- =========================================================================
    -- AXI4-Lite Internal Registers
    -- =========================================================================
    signal reg_ctrl              : std_logic_vector(31 downto 0) := x"00000003"; -- 0x00: Default Armed + Auto
    signal reg_status            : std_logic_vector(31 downto 0) := (others => '0'); -- 0x04
    signal reg_threshold         : std_logic_vector(31 downto 0) := x"00000800"; -- 0x08
    signal reg_timeout           : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(5000000, 32)); -- 0x0C
    signal reg_hysteresis        : std_logic_vector(31 downto 0) := x"00000010"; -- 0x10
    signal reg_decimation        : std_logic_vector(31 downto 0) := x"00000001"; -- 0x14: Default M=10
    signal reg_fft_config        : std_logic_vector(31 downto 0) := x"0000010A"; -- 0x18
    signal reg_packet_size       : std_logic_vector(31 downto 0) := x"00000800"; -- 0x1C: Default 2048 samples
    signal reg_pulse_width       : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(500000, 32)); -- 0x20: Default 5.0ms

    -- Hardware-Accelerated ToA / TDOA Registers
    signal reg_mic1_toa_cycles   : std_logic_vector(31 downto 0) := (others => '0'); -- 0x24: Mic 1 arrival timestamp
    signal reg_mic2_toa_cycles   : std_logic_vector(31 downto 0) := (others => '0'); -- 0x28: Mic 2 arrival timestamp
    -- 0x2C: [31:16]=Blanking cycles (30,000 = 0.30 ms), [15:0]=Threshold delta (512 counts ~ 25.8 mV)
    signal reg_toa_config        : std_logic_vector(31 downto 0) := x"75300200";
    -- 0x30: [31:16]=Mic 2 DC Ref (0x8000 = 1.65V), [15:0]=Mic 1 DC Ref (0x8000 = 1.65V)
    signal reg_mic_dc_ref        : std_logic_vector(31 downto 0) := x"80008000";

    -- Hardware Direct-Path Energy Accumulation Registers (Quasi-Anechoic Gate)
    signal reg_mic1_direct_energy: std_logic_vector(31 downto 0) := (others => '0'); -- 0x34: Mic 1 Direct Energy
    signal reg_mic2_direct_energy: std_logic_vector(31 downto 0) := (others => '0'); -- 0x38: Mic 2 Direct Energy
    -- 0x3C: [15:0]=Direct gate length N_gate (Default 576 samples = 0x0240 = 3 cycles @ 2610 Hz)
    signal reg_gate_config       : std_logic_vector(31 downto 0) := x"00000240";

    -- AXI Handshake Signals
    signal axi_awready           : std_logic := '0';
    signal axi_wready            : std_logic := '0';
    signal axi_bvalid            : std_logic := '0';
    signal axi_arready           : std_logic := '0';
    signal axi_rvalid            : std_logic := '0';
    signal axi_rdata             : std_logic_vector(31 downto 0) := (others => '0');

    -- Persistent Configuration Handshake Flag for xfft_0
    signal fft_cfg_valid_reg     : std_logic := '1';

    -- Trigger FSM State
    type t_state is (ST_IDLE, ST_ARMED, ST_STREAMING);
    signal state                 : t_state := ST_IDLE;
    signal trig_pending          : std_logic := '0';

    -- Sample Histories for Analog Edge Detection
    signal ch1_prev              : unsigned(15 downto 0) := (others => '0');
    signal ch2_prev              : unsigned(15 downto 0) := (others => '0');
    signal timeout_cnt           : unsigned(31 downto 0) := (others => '0');
    signal force_trig_reg        : std_logic := '0';

    -- Hardware Pulse Generator Signals
    signal pulse_fire_strobe     : std_logic := '0';
    signal pulse_active_reg      : std_logic := '0';
    signal pulse_down_counter    : unsigned(31 downto 0) := (others => '0');

    -- Hardware ToA / TDOA Engine Internal Signals
    signal toa_cycle_counter     : unsigned(31 downto 0) := (others => '0');
    signal toa_running           : std_logic := '0';
    signal mic1_locked           : std_logic := '0';
    signal mic2_locked           : std_logic := '0';
    signal toa_done_flag         : std_logic := '0';

    -- Hardware Direct-Path Energy Gating Internal Signals
    signal gate_cnt1             : unsigned(15 downto 0) := (others => '0');
    signal gate_cnt2             : unsigned(15 downto 0) := (others => '0');
    signal energy_acc1           : unsigned(31 downto 0) := (others => '0');
    signal energy_acc2           : unsigned(31 downto 0) := (others => '0');
    signal mic1_gate_active      : std_logic := '0';
    signal mic2_gate_active      : std_logic := '0';
    signal mic1_gate_done        : std_logic := '0';
    signal mic2_gate_done        : std_logic := '0';

    -- Control Bit Aliases
    signal cfg_arm               : std_logic;
    signal cfg_auto              : std_logic;
    signal cfg_edge_fall         : std_logic;
    signal cfg_single            : std_logic;
    signal cfg_trig_src_ch2      : std_logic;

begin

    -- Output Port Assignments
    decim_factor_out         <= reg_decimation(1 downto 0);
    packet_size_out          <= reg_packet_size(15 downto 0);
    m_axis_fft_config_tdata  <= reg_fft_config(15 downto 0);
    m_axis_fft_config_tvalid <= fft_cfg_valid_reg;
    fft_chan_sel_out         <= reg_ctrl(6);
    buzzer_pulse_out         <= pulse_active_reg;

    -- Control aliases
    cfg_arm          <= reg_ctrl(0);
    cfg_auto         <= reg_ctrl(1);
    cfg_edge_fall    <= reg_ctrl(2);
    cfg_single       <= reg_ctrl(3);
    cfg_trig_src_ch2 <= reg_ctrl(5);

    -- Status Register Mapping (0x04)
    reg_status(0) <= '1' when (state = ST_ARMED) else '0';
    reg_status(1) <= '1' when (state = ST_STREAMING) else '0';
    reg_status(2) <= '1' when (state = ST_STREAMING and s_axis_tvalid = '1') else '0';
    reg_status(3) <= pulse_active_reg;
    reg_status(4) <= mic1_locked;        -- Bit 4: Mic 1 Wavefront Locked
    reg_status(5) <= mic2_locked;        -- Bit 5: Mic 2 Wavefront Locked
    reg_status(6) <= toa_done_flag;      -- Bit 6: Both locked or timeout reached
    reg_status(7) <= mic1_gate_done;     -- Bit 7: Mic 1 Direct Gate Complete
    reg_status(8) <= mic2_gate_done;     -- Bit 8: Mic 2 Direct Gate Complete
    reg_status(31 downto 9) <= (others => '0');

    -- =========================================================================
    -- 1. AXI4-Lite Register Interface (Read/Write Handling)
    -- =========================================================================
    s_axi_awready <= axi_awready;
    s_axi_wready  <= axi_wready;
    s_axi_bresp   <= "00";
    s_axi_bvalid  <= axi_bvalid;
    s_axi_arready <= axi_arready;
    s_axi_rdata   <= axi_rdata;
    s_axi_rresp   <= "00";
    s_axi_rvalid  <= axi_rvalid;

    process(aclk)
        variable write_addr : integer;
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                axi_awready        <= '0';
                axi_wready         <= '0';
                axi_bvalid         <= '0';
                reg_ctrl           <= x"00000003";
                reg_threshold      <= x"00000800";
                reg_timeout        <= std_logic_vector(to_unsigned(5000000, 32));
                reg_hysteresis     <= x"00000010";
                reg_decimation     <= x"00000001";
                reg_fft_config     <= x"0000010A";
                reg_packet_size    <= x"00000800";
                reg_pulse_width    <= std_logic_vector(to_unsigned(500000, 32));
                reg_toa_config     <= x"75300200";
                reg_mic_dc_ref     <= x"80008000";
                reg_gate_config    <= x"00000240";
                fft_cfg_valid_reg  <= '1';
                force_trig_reg     <= '0';
                pulse_fire_strobe  <= '0';
            else
                force_trig_reg    <= '0';
                pulse_fire_strobe <= '0';
                reg_ctrl(7)       <= '0'; -- Hardware self-clearing strobe: Bit 7 reverts to '0'

                -- Clear valid when xfft_0 confirms receipt via TREADY handshake
                if fft_cfg_valid_reg = '1' and m_axis_fft_config_tready = '1' then
                    fft_cfg_valid_reg <= '0';
                end if;

                -- Address Handshake
                if (axi_awready = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1') then
                    axi_awready <= '1';
                    axi_wready  <= '1';
                else
                    axi_awready <= '0';
                    axi_wready  <= '0';
                end if;

                -- Register Write Handling (Decodes 4 bits: s_axi_awaddr(5 downto 2))
                if (axi_awready = '1' and axi_wready = '1') then
                    write_addr := to_integer(unsigned(s_axi_awaddr(5 downto 2)));
                    case write_addr is
                        when 0 => -- 0x00: CONTROL_REG
                            reg_ctrl    <= s_axi_wdata;
                            reg_ctrl(7) <= '0'; -- Ensure bit 7 is NEVER sticky in storage!
                            if s_axi_wdata(4) = '1' then
                                force_trig_reg <= '1';
                            end if;
                            if s_axi_wdata(7) = '1' then
                                pulse_fire_strobe <= '1'; -- Strobe pulse launch & reset ToA/Energy counters
                            end if;
                        when 2  => reg_threshold   <= s_axi_wdata; -- 0x08: THRESHOLD
                        when 3  => reg_timeout     <= s_axi_wdata; -- 0x0C: TIMEOUT
                        when 4  => reg_hysteresis  <= s_axi_wdata; -- 0x10: HYSTERESIS
                        when 5  => reg_decimation  <= s_axi_wdata; -- 0x14: DECIMATION
                        when 6  => -- 0x18: FFT_CONFIG
                            reg_fft_config    <= s_axi_wdata;
                            fft_cfg_valid_reg <= '1';
                        when 7  => reg_packet_size <= s_axi_wdata; -- 0x1C: PACKET_SIZE
                        when 8  => reg_pulse_width <= s_axi_wdata; -- 0x20: PULSE_WIDTH
                        when 11 => reg_toa_config  <= s_axi_wdata; -- 0x2C: TOA_CONFIG (Blanking & Threshold)
                        when 12 => reg_mic_dc_ref  <= s_axi_wdata; -- 0x30: MIC_DC_REF (Mic 1 & 2 DC Baselines)
                        when 15 => reg_gate_config <= s_axi_wdata; -- 0x3C: GATE_CONFIG (Integration length N_gate)
                        when others => null;
                    end case;
                end if;

                -- Write Response
                if (axi_awready = '1' and axi_wready = '1' and axi_bvalid = '0') then
                    axi_bvalid <= '1';
                elsif (s_axi_bready = '1' and axi_bvalid = '1') then
                    axi_bvalid <= '0';
                end if;

                -- Auto-disarm on Single-Shot frame completion
                if (state = ST_STREAMING and frame_done = '1' and cfg_single = '1') then
                    reg_ctrl(0) <= '0';
                end if;
            end if;
        end if;
    end process;

    -- Read Address & Data Handling
    process(aclk)
        variable read_addr : integer;
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                axi_arready <= '0';
                axi_rvalid  <= '0';
                axi_rdata   <= (others => '0');
            else
                if (axi_arready = '0' and s_axi_arvalid = '1') then
                    axi_arready <= '1';
                    read_addr := to_integer(unsigned(s_axi_araddr(5 downto 2)));
                    case read_addr is
                        when 0  => axi_rdata <= reg_ctrl;
                        when 1  => axi_rdata <= reg_status;
                        when 2  => axi_rdata <= reg_threshold;
                        when 3  => axi_rdata <= reg_timeout;
                        when 4  => axi_rdata <= reg_hysteresis;
                        when 5  => axi_rdata <= reg_decimation;
                        when 6  => axi_rdata <= reg_fft_config;
                        when 7  => axi_rdata <= reg_packet_size;
                        when 8  => axi_rdata <= reg_pulse_width;
                        -- Hardware-Accelerated ToA / TDOA Readbacks:
                        when 9  => axi_rdata <= reg_mic1_toa_cycles;    -- 0x24: Mic 1 Arrival (10 ns ticks)
                        when 10 => axi_rdata <= reg_mic2_toa_cycles;    -- 0x28: Mic 2 Arrival (10 ns ticks)
                        when 11 => axi_rdata <= reg_toa_config;         -- 0x2C: ToA Configuration
                        when 12 => axi_rdata <= reg_mic_dc_ref;         -- 0x30: DC References
                        -- Quasi-Anechoic Direct-Path Energy Readbacks:
                        when 13 => axi_rdata <= reg_mic1_direct_energy; -- 0x34: Mic 1 Direct Energy Sum
                        when 14 => axi_rdata <= reg_mic2_direct_energy; -- 0x38: Mic 2 Direct Energy Sum
                        when 15 => axi_rdata <= reg_gate_config;        -- 0x3C: Gate Configuration
                        when others => axi_rdata <= (others => '0');
                    end case;
                else
                    axi_arready <= '0';
                end if;

                if (axi_arready = '1' and axi_rvalid = '0') then
                    axi_rvalid <= '1';
                elsif (s_axi_rready = '1' and axi_rvalid = '1') then
                    axi_rvalid <= '0';
                end if;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- 2. Hardware Pulse Generator Process (Cycle-Accurate Down-Counter)
    -- =========================================================================
    process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                pulse_down_counter <= (others => '0');
                pulse_active_reg   <= '0';
            else
                if pulse_fire_strobe = '1' then
                    if unsigned(reg_pulse_width) > 0 then
                        pulse_down_counter <= unsigned(reg_pulse_width);
                        pulse_active_reg   <= '1';
                    else
                        pulse_down_counter <= (others => '0');
                        pulse_active_reg   <= '0';
                    end if;
                elsif pulse_down_counter > 0 then
                    if pulse_down_counter = 1 then
                        pulse_down_counter <= (others => '0');
                        pulse_active_reg   <= '0';
                    else
                        pulse_down_counter <= pulse_down_counter - 1;
                    end if;
                else
                    pulse_active_reg <= '0';
                end if;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- 3. Hardware-Accelerated ToA / TDOA Cycle Counter & Comparators (100 MHz)
    -- =========================================================================
    process(aclk)
        variable sample_val   : unsigned(15 downto 0);
        variable dc_ref_val   : unsigned(15 downto 0);
        variable thresh_val   : unsigned(15 downto 0);
        variable blanking_val : unsigned(15 downto 0);
        variable dev_val      : unsigned(15 downto 0);
        variable is_ch1       : boolean;
        variable is_ch2       : boolean;
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                toa_cycle_counter   <= (others => '0');
                toa_running         <= '0';
                mic1_locked         <= '0';
                mic2_locked         <= '0';
                toa_done_flag       <= '0';
                reg_mic1_toa_cycles <= (others => '0');
                reg_mic2_toa_cycles <= (others => '0');
            else
                -- Synchronous pulse trigger reset
                if pulse_fire_strobe = '1' then
                    toa_cycle_counter   <= (others => '0');
                    toa_running         <= '1';
                    mic1_locked         <= '0';
                    mic2_locked         <= '0';
                    toa_done_flag       <= '0';
                    reg_mic1_toa_cycles <= (others => '0');
                    reg_mic2_toa_cycles <= (others => '0');

                elsif toa_running = '1' then
                    -- Increment 100 MHz cycle counter (10.0 ns resolution)
                    toa_cycle_counter <= toa_cycle_counter + 1;

                    thresh_val   := unsigned(reg_toa_config(15 downto 0));
                    blanking_val := unsigned(reg_toa_config(31 downto 16));

                    -- Check incoming ADC samples after blanking window elapses
                    if (s_axis_tvalid = '1') and (toa_cycle_counter >= blanking_val) then
                        sample_val := unsigned(s_axis_tdata);
                        is_ch1     := (channel_id = CH_VAUX1);
                        is_ch2     := (channel_id = CH_VAUX9);

                        -- Channel 1 (Mic 1 / A0) Comparator
                        if is_ch1 and (mic1_locked = '0') then
                            dc_ref_val := unsigned(reg_mic_dc_ref(15 downto 0));
                            if sample_val >= dc_ref_val then
                                dev_val := sample_val - dc_ref_val;
                            else
                                dev_val := dc_ref_val - sample_val;
                            end if;

                            if dev_val >= thresh_val then
                                reg_mic1_toa_cycles <= std_logic_vector(toa_cycle_counter);
                                mic1_locked         <= '1';
                            end if;
                        end if;

                        -- Channel 2 (Mic 2 / A1) Comparator
                        if is_ch2 and (mic2_locked = '0') then
                            dc_ref_val := unsigned(reg_mic_dc_ref(31 downto 16));
                            if sample_val >= dc_ref_val then
                                dev_val := sample_val - dc_ref_val;
                            else
                                dev_val := dc_ref_val - sample_val;
                            end if;

                            if dev_val >= thresh_val then
                                reg_mic2_toa_cycles <= std_logic_vector(toa_cycle_counter);
                                mic2_locked         <= '1';
                            end if;
                        end if;
                    end if;

                    -- Termination condition: both microphones locked or 50 ms timeout reached
                    if (mic1_locked = '1' and mic2_locked = '1') or (toa_cycle_counter >= TOA_TIMEOUT_CYCLES) then
                        toa_running   <= '0';
                        toa_done_flag <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- 4. Quasi-Anechoic Direct-Path Energy Accumulation Process
    -- =========================================================================
    process(aclk)
        variable sample_12     : unsigned(11 downto 0);
        variable dc_ref_12     : unsigned(11 downto 0);
        variable dev_12        : unsigned(11 downto 0);
        variable dev_sq        : unsigned(23 downto 0);
        variable n_gate_target : unsigned(15 downto 0);
        variable is_ch1        : boolean;
        variable is_ch2        : boolean;
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                gate_cnt1              <= (others => '0');
                gate_cnt2              <= (others => '0');
                energy_acc1            <= (others => '0');
                energy_acc2            <= (others => '0');
                mic1_gate_active       <= '0';
                mic2_gate_active       <= '0';
                mic1_gate_done         <= '0';
                mic2_gate_done         <= '0';
                reg_mic1_direct_energy <= (others => '0');
                reg_mic2_direct_energy <= (others => '0');
            else
                -- Synchronous reset on pulse fire strobe
                if pulse_fire_strobe = '1' then
                    gate_cnt1              <= (others => '0');
                    gate_cnt2              <= (others => '0');
                    energy_acc1            <= (others => '0');
                    energy_acc2            <= (others => '0');
                    mic1_gate_active       <= '0';
                    mic2_gate_active       <= '0';
                    mic1_gate_done         <= '0';
                    mic2_gate_done         <= '0';
                    reg_mic1_direct_energy <= (others => '0');
                    reg_mic2_direct_energy <= (others => '0');
                else
                    n_gate_target := unsigned(reg_gate_config(15 downto 0));
                    if n_gate_target = 0 then
                        n_gate_target := to_unsigned(576, 16);
                    end if;

                    -- Trigger gate activation on respective wavefront lock
                    if mic1_locked = '1' and mic1_gate_done = '0' then
                        mic1_gate_active <= '1';
                    end if;

                    if mic2_locked = '1' and mic2_gate_done = '0' then
                        mic2_gate_active <= '1';
                    end if;

                    -- Process incoming stream samples
                    if s_axis_tvalid = '1' then
                        is_ch1 := (channel_id = CH_VAUX1);
                        is_ch2 := (channel_id = CH_VAUX9);

                        -- -----------------------------------------------------
                        -- Channel 1 (Mic 1 / A0) Direct-Path Accumulation
                        -- -----------------------------------------------------
                        if is_ch1 and (mic1_gate_active = '1') and (mic1_gate_done = '0') then
                            sample_12 := unsigned(s_axis_tdata(15 downto 4));
                            dc_ref_12 := unsigned(reg_mic_dc_ref(15 downto 4));

                            if sample_12 >= dc_ref_12 then
                                dev_12 := sample_12 - dc_ref_12;
                            else
                                dev_12 := dc_ref_12 - sample_12;
                            end if;

                            dev_sq      := dev_12 * dev_12;
                            energy_acc1 <= energy_acc1 + resize(dev_sq, 32);

                            if gate_cnt1 >= (n_gate_target - 1) then
                                reg_mic1_direct_energy <= std_logic_vector(energy_acc1 + resize(dev_sq, 32));
                                mic1_gate_active       <= '0';
                                mic1_gate_done         <= '1';
                            else
                                gate_cnt1 <= gate_cnt1 + 1;
                            end if;
                        end if;

                        -- -----------------------------------------------------
                        -- Channel 2 (Mic 2 / A1) Direct-Path Accumulation
                        -- -----------------------------------------------------
                        if is_ch2 and (mic2_gate_active = '1') and (mic2_gate_done = '0') then
                            sample_12 := unsigned(s_axis_tdata(15 downto 4));
                            dc_ref_12 := unsigned(reg_mic_dc_ref(31 downto 20));

                            if sample_12 >= dc_ref_12 then
                                dev_12 := sample_12 - dc_ref_12;
                            else
                                dev_12 := dc_ref_12 - sample_12;
                            end if;

                            dev_sq      := dev_12 * dev_12;
                            energy_acc2 <= energy_acc2 + resize(dev_sq, 32);

                            if gate_cnt2 >= (n_gate_target - 1) then
                                reg_mic2_direct_energy <= std_logic_vector(energy_acc2 + resize(dev_sq, 32));
                                mic2_gate_active       <= '0';
                                mic2_gate_done         <= '1';
                            else
                                gate_cnt2 <= gate_cnt2 + 1;
                            end if;
                        end if;

                    end if;
                end if;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- 5. Streaming Pass-Through & Trigger Engine
    -- =========================================================================
    m_axis_tdata  <= s_axis_tdata;
    m_axis_tvalid <= s_axis_tvalid when (state = ST_STREAMING) else '0';
    s_axis_tready <= m_axis_tready when (state = ST_STREAMING) else '1';

    process(aclk)
        variable thresh_val      : unsigned(15 downto 0);
        variable cur_sample      : unsigned(15 downto 0);
        variable is_ch1          : boolean;
        variable is_ch2          : boolean;
        variable is_trig_channel : boolean;
        variable prev_val        : unsigned(15 downto 0);
        variable is_rising       : boolean;
        variable is_falling      : boolean;
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                state          <= ST_IDLE;
                trig_pending   <= '0';
                ch1_prev       <= (others => '0');
                ch2_prev       <= (others => '0');
                timeout_cnt    <= (others => '0');
            else
                thresh_val := unsigned(reg_threshold(15 downto 0));
                cur_sample := unsigned(s_axis_tdata);
                is_ch1     := (channel_id = CH_VAUX1);
                is_ch2     := (channel_id = CH_VAUX9);

                if cfg_trig_src_ch2 = '0' then
                    is_trig_channel := is_ch1;
                    prev_val        := ch1_prev;
                else
                    is_trig_channel := is_ch2;
                    prev_val        := ch2_prev;
                end if;

                if s_axis_tvalid = '1' then
                    if is_ch1 then
                        ch1_prev <= cur_sample;
                    elsif is_ch2 then
                        ch2_prev <= cur_sample;
                    end if;
                end if;

                is_rising  := (prev_val < thresh_val) and (cur_sample >= thresh_val);
                is_falling := (prev_val > thresh_val) and (cur_sample <= thresh_val);

                case state is
                    when ST_IDLE =>
                        timeout_cnt  <= (others => '0');
                        trig_pending <= '0';
                        if cfg_arm = '1' then
                            state <= ST_ARMED;
                        end if;

                    when ST_ARMED =>
                        if cfg_arm = '0' then
                            state <= ST_IDLE;
                            trig_pending <= '0';
                        else
                            -- Pulse Trigger or Force Strobe
                            if pulse_fire_strobe = '1' or force_trig_reg = '1' then
                                trig_pending <= '1';
                            elsif (s_axis_tvalid = '1') and is_trig_channel and (
                                  (cfg_edge_fall = '0' and is_rising) or
                                  (cfg_edge_fall = '1' and is_falling)
                                  ) then
                                trig_pending <= '1';
                            elsif cfg_auto = '1' then
                                if timeout_cnt >= unsigned(reg_timeout) then
                                    trig_pending <= '1';
                                else
                                    timeout_cnt <= timeout_cnt + 1;
                                end if;
                            end if;

                            -- Phase Alignment: Always start streaming on Channel 1 (A0)
                            if (trig_pending = '1') and (s_axis_tvalid = '1') and is_ch1 then
                                timeout_cnt  <= (others => '0');
                                trig_pending <= '0';
                                state        <= ST_STREAMING;
                            end if;
                        end if;

                    when ST_STREAMING =>
                        if (frame_done = '1' and s_axis_tvalid = '1' and m_axis_tready = '1') then
                            if cfg_single = '1' then
                                state <= ST_IDLE;
                            elsif cfg_arm = '1' then
                                state <= ST_ARMED;
                            else
                                state <= ST_IDLE;
                            end if;
                        end if;
                end case;
            end if;
        end if;
    end process;

end Behavioral;