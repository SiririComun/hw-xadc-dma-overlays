-- =============================================================================
-- File: axis_trigger_unit.vhd
-- Description: Central Acquisition, Edge Trigger & Runtime Configuration Controller.
--              Hosts AXI4-Lite registers to dynamically control:
--                • Hardware Edge/Level Triggering (A0 vs A1)
--                • FFT Input Channel Stream Selection (A0 vs A1 via Bit 6)
--                • Decimation Ratio (M = 1, 10, 20, 50)
--                • LogiCORE FFT Transform Length (NFFT = 512, 1024, 2048 via 16-bit config)
--                • TLAST Packet Size (512, 1024, 2048)
--                • Persistent AXI4-Stream Handshake on m_axis_fft_config
-- =============================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity axis_trigger_unit is
    generic (
        C_S_AXI_DATA_WIDTH : integer := 32;
        C_S_AXI_ADDR_WIDTH : integer := 5
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
        -- Runtime Configuration Outputs
        -- =====================================================================
        -- Decimation factor selector to axis_decimator_0 (00=M=1, 01=M=10, 10=M=20, 11=M=50)
        decim_factor_out         : out std_logic_vector(1 downto 0);

        -- Runtime FFT Configuration Master Stream to xfft_0 (With TREADY Handshake!)
        m_axis_fft_config_tdata  : out std_logic_vector(15 downto 0);
        m_axis_fft_config_tvalid : out std_logic;
        m_axis_fft_config_tready : in  std_logic;

        -- Programmable packet size to tlast_generator_0
        packet_size_out          : out std_logic_vector(15 downto 0);

        -- FFT Channel Selector (0 = Route A0/CH1 to FFT, 1 = Route A1/CH2 to FFT)
        fft_chan_sel_out         : out std_logic
    );
end axis_trigger_unit;

architecture Behavioral of axis_trigger_unit is

    -- Constant Channel Addresses in 7-Series XADC
    constant CH_VAUX1            : std_logic_vector(4 downto 0) := "10001"; -- 0x11 (Channel 1 / A0)
    constant CH_VAUX9            : std_logic_vector(4 downto 0) := "11001"; -- 0x19 (Channel 2 / A1)

    -- Register Offsets (Byte-addressed via s_axi_awaddr[4:2])
    -- reg_ctrl: [0]=Arm, [1]=Auto, [2]=Falling Edge, [3]=Single Shot, [4]=Force Trig, [5]=Trig Src (0=A0, 1=A1), [6]=FFT Src (0=A0, 1=A1)
    signal reg_ctrl              : std_logic_vector(31 downto 0) := x"00000003"; -- Default: Armed + Auto + CH1 Trig + CH1 FFT
    signal reg_status            : std_logic_vector(31 downto 0) := (others => '0'); -- 0x04
    signal reg_threshold         : std_logic_vector(31 downto 0) := x"00000800"; -- 0x08: Default 1.65V
    signal reg_timeout           : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(5000000, 32)); -- 0x0C: 50ms
    signal reg_hysteresis        : std_logic_vector(31 downto 0) := x"00000010"; -- 0x10
    signal reg_decimation        : std_logic_vector(31 downto 0) := x"00000001"; -- 0x14: Default M=10
    -- PG109 Format: Byte 0 = NFFT (10 = 0x0A for 1024-pt), Byte 1 = FWD_INV (1 = Forward) -> 0x0000010A
    signal reg_fft_config        : std_logic_vector(31 downto 0) := x"0000010A"; -- 0x18: Default 1024-pt Forward FFT
    signal reg_packet_size       : std_logic_vector(31 downto 0) := x"00000800"; -- 0x1C: Default 2048 samples

    -- AXI Handshake Signals
    signal axi_awready           : std_logic := '0';
    signal axi_wready            : std_logic := '0';
    signal axi_bvalid            : std_logic := '0';
    signal axi_arready           : std_logic := '0';
    signal axi_rvalid            : std_logic := '0';
    signal axi_rdata             : std_logic_vector(31 downto 0) := (others => '0');

    -- Persistent Configuration Handshake Flag for xfft_0 (Holds valid high until TREADY arrives)
    signal fft_cfg_valid_reg     : std_logic := '1';

    -- Trigger FSM State
    type t_state is (ST_IDLE, ST_ARMED, ST_STREAMING);
    signal state                 : t_state := ST_IDLE;
    signal trig_pending          : std_logic := '0';

    -- Sample Histories for Edge Detection
    signal ch1_prev              : unsigned(15 downto 0) := (others => '0');
    signal ch2_prev              : unsigned(15 downto 0) := (others => '0');

    signal timeout_cnt           : unsigned(31 downto 0) := (others => '0');
    signal force_trig_reg        : std_logic := '0';

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
    m_axis_fft_config_tdata  <= reg_fft_config(15 downto 0); -- 16-bit word (0x010A for N=1024 FWD)
    m_axis_fft_config_tvalid <= fft_cfg_valid_reg;
    fft_chan_sel_out         <= reg_ctrl(6);                 -- Bit 6: 0 = Route A0 (CH1) to FFT, 1 = Route A1 (CH2) to FFT

    -- Control aliases
    cfg_arm          <= reg_ctrl(0);
    cfg_auto         <= reg_ctrl(1);
    cfg_edge_fall    <= reg_ctrl(2);
    cfg_single       <= reg_ctrl(3);
    cfg_trig_src_ch2 <= reg_ctrl(5); -- Bit 5: 0 = Trigger on A0, 1 = Trigger on A1

    -- Status mapping
    reg_status(0) <= '1' when (state = ST_ARMED) else '0';
    reg_status(1) <= '1' when (state = ST_STREAMING) else '0';
    reg_status(2) <= '1' when (state = ST_STREAMING and s_axis_tvalid = '1') else '0';
    reg_status(31 downto 3) <= (others => '0');

    -- =========================================================================
    -- 1. AXI4-Lite Register Interface
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
                reg_decimation     <= x"00000001"; -- Default M=10
                reg_fft_config     <= x"0000010A"; -- Default N=1024, FWD (PG109)
                reg_packet_size    <= x"00000800"; -- Default 2048
                fft_cfg_valid_reg  <= '1';         -- Hold high on startup until xfft_0 is ready!
                force_trig_reg     <= '0';
            else
                force_trig_reg <= '0';

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

                -- Register Write Handling
                if (axi_awready = '1' and axi_wready = '1') then
                    write_addr := to_integer(unsigned(s_axi_awaddr(4 downto 2)));
                    case write_addr is
                        when 0 => -- 0x00: CONTROL
                            reg_ctrl <= s_axi_wdata;
                            if s_axi_wdata(4) = '1' then
                                force_trig_reg <= '1';
                            end if;
                        when 2 => reg_threshold   <= s_axi_wdata; -- 0x08: THRESHOLD
                        when 3 => reg_timeout     <= s_axi_wdata; -- 0x0C: TIMEOUT
                        when 4 => reg_hysteresis  <= s_axi_wdata; -- 0x10: HYSTERESIS
                        when 5 => reg_decimation  <= s_axi_wdata; -- 0x14: DECIMATION
                        when 6 => -- 0x18: FFT_CONFIG
                            reg_fft_config    <= s_axi_wdata;
                            fft_cfg_valid_reg <= '1';             -- Hold valid high until xfft_0 asserts TREADY!
                        when 7 => reg_packet_size <= s_axi_wdata; -- 0x1C: PACKET_SIZE
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
                    read_addr := to_integer(unsigned(s_axi_araddr(4 downto 2)));
                    case read_addr is
                        when 0 => axi_rdata <= reg_ctrl;
                        when 1 => axi_rdata <= reg_status;
                        when 2 => axi_rdata <= reg_threshold;
                        when 3 => axi_rdata <= reg_timeout;
                        when 4 => axi_rdata <= reg_hysteresis;
                        when 5 => axi_rdata <= reg_decimation;
                        when 6 => axi_rdata <= reg_fft_config;
                        when 7 => axi_rdata <= reg_packet_size;
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
    -- 2. Streaming Pass-Through & Trigger Engine
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
                            -- 1. Software Force Trigger
                            if force_trig_reg = '1' then
                                trig_pending <= '1';

                            -- 2. Hardware Edge on selected trigger source
                            elsif (s_axis_tvalid = '1') and is_trig_channel and (
                                  (cfg_edge_fall = '0' and is_rising) or
                                  (cfg_edge_fall = '1' and is_falling)
                                  ) then
                                trig_pending <= '1';

                            -- 3. Auto-Timeout Fallback
                            elsif cfg_auto = '1' then
                                if timeout_cnt >= unsigned(reg_timeout) then
                                    trig_pending <= '1';
                                else
                                    timeout_cnt <= timeout_cnt + 1;
                                end if;
                            end if;

                            -- Always start packet on Channel 1 (A0) for deterministic alignment
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