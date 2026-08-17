library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity axis_trigger_unit is
    generic (
        C_S_AXI_DATA_WIDTH : integer := 32;
        C_S_AXI_ADDR_WIDTH : integer := 5
    );
    port (
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
        -- Hardware Channel Identifier from XADC (0x11 = Vaux1/A0, 0x19 = Vaux9/A1)
        -- =====================================================================
        channel_id         : in  std_logic_vector(4 downto 0);

        -- =====================================================================
        -- AXI4-Stream Slave Interface (Raw Samples from XADC)
        -- =====================================================================
        s_axis_tdata       : in  std_logic_vector(15 downto 0);
        s_axis_tvalid      : in  std_logic;
        s_axis_tready      : out std_logic;

        -- =====================================================================
        -- AXI4-Stream Master Interface (Trigger-Gated Stream)
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

    -- Constant Channel Addresses in 7-Series XADC
    constant CH_VAUX1      : std_logic_vector(4 downto 0) := "10001"; -- 0x11 (Channel 1 / A0)
    constant CH_VAUX9      : std_logic_vector(4 downto 0) := "11001"; -- 0x19 (Channel 2 / A1)

    -- Register Offsets (Byte-addressed)
    -- 0x00: CONTROL_REG [0:Arm, 1:Auto, 2:Edge, 3:Single, 4:Force, 5:TrigSource(0=A0, 1=A1)]
    signal reg_ctrl        : std_logic_vector(31 downto 0) := x"00000003"; -- Default: Armed + Auto Mode + CH1
    signal reg_status      : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_threshold   : std_logic_vector(31 downto 0) := x"00000800"; -- Default: Mid-scale (1.65V)
    signal reg_timeout     : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(5000000, 32));
    signal reg_hysteresis  : std_logic_vector(31 downto 0) := x"00000010";

    -- AXI Handshakes
    signal axi_awready     : std_logic := '0';
    signal axi_wready      : std_logic := '0';
    signal axi_bvalid      : std_logic := '0';
    signal axi_arready     : std_logic := '0';
    signal axi_rvalid      : std_logic := '0';
    signal axi_rdata       : std_logic_vector(31 downto 0) := (others => '0');

    -- Trigger FSM
    type t_state is (ST_IDLE, ST_ARMED, ST_STREAMING);
    signal state           : t_state := ST_IDLE;
    signal trig_pending    : std_logic := '0';

    -- Independent Channel Sample Histories for Zero-Skew Edge Detection
    signal ch1_prev        : unsigned(15 downto 0) := (others => '0');
    signal ch2_prev        : unsigned(15 downto 0) := (others => '0');

    signal timeout_cnt     : unsigned(31 downto 0) := (others => '0');
    signal force_trig_reg  : std_logic := '0';

    -- Control Bit Aliases
    signal cfg_arm         : std_logic;
    signal cfg_auto        : std_logic;
    signal cfg_edge_fall   : std_logic;
    signal cfg_single      : std_logic;
    signal cfg_trig_src_ch2: std_logic;

begin

    cfg_arm          <= reg_ctrl(0);
    cfg_auto         <= reg_ctrl(1);
    cfg_edge_fall    <= reg_ctrl(2);
    cfg_single       <= reg_ctrl(3);
    cfg_trig_src_ch2 <= reg_ctrl(5); -- Bit 5: 0 = Trigger on A0, 1 = Trigger on A1

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
                axi_awready <= '0';
                axi_wready  <= '0';
                axi_bvalid  <= '0';
                reg_ctrl    <= x"00000003";
                reg_threshold  <= x"00000800";
                reg_timeout    <= std_logic_vector(to_unsigned(5000000, 32));
                reg_hysteresis <= x"00000010";
                force_trig_reg <= '0';
            else
                force_trig_reg <= '0';

                if (axi_awready = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1') then
                    axi_awready <= '1';
                    axi_wready  <= '1';
                else
                    axi_awready <= '0';
                    axi_wready  <= '0';
                end if;

                if (axi_awready = '1' and axi_wready = '1') then
                    write_addr := to_integer(unsigned(s_axi_awaddr(4 downto 2)));
                    case write_addr is
                        when 0 =>
                            reg_ctrl <= s_axi_wdata;
                            if s_axi_wdata(4) = '1' then
                                force_trig_reg <= '1';
                            end if;
                        when 2 => reg_threshold <= s_axi_wdata;
                        when 3 => reg_timeout <= s_axi_wdata;
                        when 4 => reg_hysteresis <= s_axi_wdata;
                        when others => null;
                    end case;
                end if;

                if (axi_awready = '1' and axi_wready = '1' and axi_bvalid = '0') then
                    axi_bvalid <= '1';
                elsif (s_axi_bready = '1' and axi_bvalid = '1') then
                    axi_bvalid <= '0';
                end if;

                if (state = ST_STREAMING and frame_done = '1' and cfg_single = '1') then
                    reg_ctrl(0) <= '0';
                end if;
            end if;
        end if;
    end process;

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
    -- 2. Streaming Pass-Through & Trigger Logic
    -- =========================================================================
    m_axis_tdata  <= s_axis_tdata;
    m_axis_tvalid <= s_axis_tvalid when (state = ST_STREAMING) else '0';
    s_axis_tready <= m_axis_tready when (state = ST_STREAMING) else '1';

    -- Synchronous Trigger Engine with Channel Source Selection & Fixed A0 Alignment
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

                -- Select active trigger channel based on Control Register Bit 5
                if cfg_trig_src_ch2 = '0' then
                    is_trig_channel := is_ch1;
                    prev_val        := ch1_prev;
                else
                    is_trig_channel := is_ch2;
                    prev_val        := ch2_prev;
                end if;

                -- Maintain independent channel sample histories
                if s_axis_tvalid = '1' then
                    if is_ch1 then
                        ch1_prev <= cur_sample;
                    elsif is_ch2 then
                        ch2_prev <= cur_sample;
                    end if;
                end if;

                -- Edge evaluation strictly on the chosen channel's data
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
                            -- 1. Check Software Force Trigger
                            if force_trig_reg = '1' then
                                trig_pending <= '1';

                            -- 2. Check Hardware Edge on Selected Trigger Channel
                            elsif (s_axis_tvalid = '1') and is_trig_channel and (
                                  (cfg_edge_fall = '0' and is_rising) or
                                  (cfg_edge_fall = '1' and is_falling)
                                  ) then
                                trig_pending <= '1';

                            -- 3. Check Auto Timeout
                            elsif cfg_auto = '1' then
                                if timeout_cnt >= unsigned(reg_timeout) then
                                    trig_pending <= '1';
                                else
                                    timeout_cnt <= timeout_cnt + 1;
                                end if;
                            end if;

                            -- DETERMINISTIC PACKET START: Always begin DMA frame on Channel 1 (A0)
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