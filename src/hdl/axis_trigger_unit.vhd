library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity axis_trigger_unit is
    generic (
        C_S_AXI_DATA_WIDTH : integer := 32;
        C_S_AXI_ADDR_WIDTH : integer := 5
    );
    port (
        -- Clock and Reset (Synchronous with Processing System AXI clock)
        aclk               : in  std_logic;
        aresetn            : in  std_logic;

        -- =====================================================================
        -- AXI4-Lite Slave Interface (Control & Status Registers)
        -- =====================================================================
        s_axi_awaddr       : in  std_logic_vector(C_S_AXI_ADDR_WIDTH - 1 downto 0);
        s_axi_awprot       : in  std_logic_vector(2 downto 0);
        s_axi_awvalid      : in  std_logic;
        s_axi_awready      : out std_logic;
        s_axi_wdata        : in  std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
        s_axi_wstrb        : in  std_logic_vector((C_S_AXI_DATA_WIDTH / 8) - 1 downto 0);
        s_axi_wvalid       : in  std_logic;
        s_axi_wready       : out std_logic;
        s_axi_bresp        : out std_logic_vector(1 downto 0);
        s_axi_bvalid       : out std_logic;
        s_axi_bready       : in  std_logic;
        s_axi_araddr       : in  std_logic_vector(C_S_AXI_ADDR_WIDTH - 1 downto 0);
        s_axi_arprot       : in  std_logic_vector(2 downto 0);
        s_axi_arvalid      : in  std_logic;
        s_axi_arready      : out std_logic;
        s_axi_rdata        : out std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
        s_axi_rresp        : out std_logic_vector(1 downto 0);
        s_axi_rvalid       : out std_logic;
        s_axi_rready       : in  std_logic;

        -- =====================================================================
        -- AXI4-Stream Slave Interface (Raw Continuous Samples from XADC)
        -- =====================================================================
        s_axis_tdata       : in  std_logic_vector(15 downto 0);
        s_axis_tvalid      : in  std_logic;
        s_axis_tready      : out std_logic;

        -- =====================================================================
        -- AXI4-Stream Master Interface (Trigger-Gated Stream to Packetizer)
        -- =====================================================================
        m_axis_tdata       : out std_logic_vector(15 downto 0);
        m_axis_tvalid      : out std_logic;
        m_axis_tready      : in  std_logic;

        -- =====================================================================
        -- Frame Feedback (Connected to tlast_generator's m_axis_tlast)
        -- =====================================================================
        frame_done         : in  std_logic
    );
end axis_trigger_unit;

architecture Behavioral of axis_trigger_unit is

    -- Register Offsets (Byte-addressed)
    -- 0x00: CONTROL_REG   [0: Arm, 1: Auto, 2: Edge(0=Rise, 1=Fall), 3: SingleShot, 4: Force]
    -- 0x04: STATUS_REG    [0: Armed, 1: Triggered, 2: Streaming]
    -- 0x08: THRESHOLD_REG [15:0] ADC Threshold Code
    -- 0x0C: TIMEOUT_REG   [31:0] Auto-trigger timeout in clock cycles (Default: 5M = 50ms)
    -- 0x10: HYSTERESIS_REG[15:0] Noise reject band
    signal reg_ctrl        : std_logic_vector(31 downto 0) := x"00000003"; -- Default: Armed + Auto Mode
    signal reg_status      : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_threshold   : std_logic_vector(31 downto 0) := x"00000800"; -- Default: Mid-scale (1.65V)
    signal reg_timeout     : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(5000000, 32));
    signal reg_hysteresis  : std_logic_vector(31 downto 0) := x"00000010"; -- Default: 16 ADC counts

    -- AXI-Lite Handshake Signals
    signal axi_awready     : std_logic := '0';
    signal axi_wready      : std_logic := '0';
    signal axi_bvalid      : std_logic := '0';
    signal axi_arready     : std_logic := '0';
    signal axi_rvalid      : std_logic := '0';
    signal axi_rdata       : std_logic_vector(31 downto 0) := (others => '0');

    -- Trigger FSM State
    type t_state is (ST_IDLE, ST_ARMED, ST_STREAMING);
    signal state : t_state := ST_IDLE;

    -- Edge Detection Pipeline
    signal sample_curr     : unsigned(15 downto 0) := (others => '0');
    signal sample_prev     : unsigned(15 downto 0) := (others => '0');
    signal sample_valid_d  : std_logic := '0';

    -- Timeout Counter for Auto Mode
    signal timeout_cnt     : unsigned(31 downto 0) := (others => '0');
    signal force_trig_reg  : std_logic := '0';

    -- Internal Control Bits
    signal cfg_arm         : std_logic;
    signal cfg_auto        : std_logic;
    signal cfg_edge_fall   : std_logic;
    signal cfg_single      : std_logic;

begin

    -- Control register bit aliases
    cfg_arm       <= reg_ctrl(0);
    cfg_auto      <= reg_ctrl(1);
    cfg_edge_fall <= reg_ctrl(2);
    cfg_single    <= reg_ctrl(3);

    -- Status register mapping
    reg_status(0) <= '1' when (state = ST_ARMED) else '0';
    reg_status(1) <= '1' when (state = ST_STREAMING) else '0';
    reg_status(2) <= '1' when (state = ST_STREAMING and s_axis_tvalid = '1') else '0';
    reg_status(31 downto 3) <= (others => '0');

    -- =========================================================================
    -- 1. AXI4-Lite Register Interface
    -- =========================================================================
    s_axi_awready <= axi_awready;
    s_axi_wready  <= axi_wready;
    s_axi_bresp   <= "00"; -- OKAY
    s_axi_bvalid  <= axi_bvalid;
    s_axi_arready <= axi_arready;
    s_axi_rdata   <= axi_rdata;
    s_axi_rresp   <= "00"; -- OKAY
    s_axi_rvalid  <= axi_rvalid;

    -- Write Address & Data Handling
    process(aclk)
        variable write_addr : integer;
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                axi_awready <= '0';
                axi_wready  <= '0';
                axi_bvalid  <= '0';
                reg_ctrl    <= x"00000003";
                reg_threshold  <= x"00000800";
                reg_timeout    <= std_logic_vector(to_unsigned(5000000, 32));
                reg_hysteresis <= x"00000010";
                force_trig_reg <= '0';
            else
                -- Auto-clear single-cycle force trigger bit
                force_trig_reg <= '0';

                -- Address handshake
                if (axi_awready = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1') then
                    axi_awready <= '1';
                    axi_wready  <= '1';
                else
                    axi_awready <= '0';
                    axi_wready  <= '0';
                end if;

                -- Register Write
                if (axi_awready = '1' and axi_wready = '1') then
                    write_addr := to_integer(unsigned(s_axi_awaddr(4 downto 2)));
                    case write_addr is
                        when 0 => -- 0x00: CONTROL
                            reg_ctrl <= s_axi_wdata;
                            if s_axi_wdata(4) = '1' then
                                force_trig_reg <= '1';
                            end if;
                        when 2 => -- 0x08: THRESHOLD
                            reg_threshold <= s_axi_wdata;
                        when 3 => -- 0x0C: TIMEOUT
                            reg_timeout <= s_axi_wdata;
                        when 4 => -- 0x10: HYSTERESIS
                            reg_hysteresis <= s_axi_wdata;
                        when others =>
                            null;
                    end case;
                end if;

                -- Write Response
                if (axi_awready = '1' and axi_wready = '1' and axi_bvalid = '0') then
                    axi_bvalid <= '1';
                elsif (s_axi_bready = '1' and axi_bvalid = '1') then
                    axi_bvalid <= '0';
                end if;

                -- Auto-disarm in Single-Shot mode when frame finishes
                if (state = ST_STREAMING and frame_done = '1' and cfg_single = '1') then
                    reg_ctrl(0) <= '0'; -- Clear ARM bit
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
    -- 2. Trigger FSM & Streaming Multiplexer
    -- =========================================================================

    -- Stream Pass-Through when in STREAMING state, otherwise drop/hold
    m_axis_tdata  <= s_axis_tdata;
    m_axis_tvalid <= s_axis_tvalid when (state = ST_STREAMING) else '0';
    s_axis_tready <= m_axis_tready when (state = ST_STREAMING) else '1'; -- Consume to keep XADC flowing

    process(aclk)
        variable thresh_val : unsigned(15 downto 0);
        variable hyst_val   : unsigned(15 downto 0);
        variable is_rising_edge  : boolean;
        variable is_falling_edge : boolean;
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                state          <= ST_IDLE;
                sample_curr    <= (others => '0');
                sample_prev    <= (others => '0');
                sample_valid_d <= '0';
                timeout_cnt    <= (others => '0');
            else
                thresh_val := unsigned(reg_threshold(15 downto 0));
                hyst_val   := unsigned(reg_hysteresis(15 downto 0));

                -- Sample Pipeline for Edge Detection
                if s_axis_tvalid = '1' then
                    sample_prev <= sample_curr;
                    sample_curr <= unsigned(s_axis_tdata);
                end if;
                sample_valid_d <= s_axis_tvalid;

                -- Edge evaluation
                is_rising_edge  := (sample_prev < thresh_val) and (sample_curr >= thresh_val);
                is_falling_edge := (sample_prev > thresh_val) and (sample_curr <= thresh_val);

                case state is
                    -- ---------------------------------------------------------
                    when ST_IDLE =>
                        timeout_cnt <= (others => '0');
                        if cfg_arm = '1' then
                            state <= ST_ARMED;
                        end if;

                    -- ---------------------------------------------------------
                    when ST_ARMED =>
                        -- Check disarm command
                        if cfg_arm = '0' then
                            state <= ST_IDLE;
                        else
                            -- 1. Check Forced Trigger (Software command)
                            if force_trig_reg = '1' then
                                timeout_cnt <= (others => '0');
                                state <= ST_STREAMING;

                            -- 2. Check Hardware Edge Condition on valid sample
                            elsif (sample_valid_d = '1') and (
                                  (cfg_edge_fall = '0' and is_rising_edge) or
                                  (cfg_edge_fall = '1' and is_falling_edge)
                                  ) then
                                timeout_cnt <= (others => '0');
                                state <= ST_STREAMING;

                            -- 3. Check Auto-Trigger Timeout
                            elsif cfg_auto = '1' then
                                if timeout_cnt >= unsigned(reg_timeout) then
                                    timeout_cnt <= (others => '0');
                                    state <= ST_STREAMING; -- Force trigger on timeout
                                else
                                    timeout_cnt <= timeout_cnt + 1;
                                end if;
                            end if;
                        end if;

                    -- ---------------------------------------------------------
                    when ST_STREAMING =>
                        -- Wait until the packetizer completes the frame (TLAST asserted)
                        if (frame_done = '1' and s_axis_tvalid = '1' and m_axis_tready = '1') then
                            if cfg_single = '1' then
                                state <= ST_IDLE;   -- Single shot finishes in IDLE
                            elsif cfg_arm = '1' then
                                state <= ST_ARMED;  -- Continuous mode re-arms for next frame
                            else
                                state <= ST_IDLE;
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process;

end Behavioral;