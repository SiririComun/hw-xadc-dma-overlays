-- =============================================================================
-- File: axis_decimator.vhd
-- Description: Runtime-Configurable Dual-Channel AXI4-Stream Decimator
--              Supports dynamic switching between:
--                • "00": M = 1  (Bypass: 500 kSPS Wideband Lab Scope)
--                • "01": M = 10 (50 kSPS Full Audio)
--                • "10": M = 20 (25 kSPS Speech / Acoustic)
--                • "11": M = 50 (10 kSPS Deep Bass Zoom, Δf = 4.88 Hz)
--              Features DSP48-accelerated fixed-point reciprocal multiplication
--              and 1-cycle pipelined averaging to guarantee 100 MHz timing closure.
-- =============================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity axis_decimator is
    port (
        aclk          : in  std_logic;
        aresetn       : in  std_logic;

        -- =====================================================================
        -- Runtime Decimation Selector (from axis_trigger_unit register 0x14)
        -- =====================================================================
        decim_sel     : in  std_logic_vector(1 downto 0);

        -- =====================================================================
        -- Hardware Channel Identifier from XADC (0x11 = Vaux1/A0, 0x19 = Vaux9/A1)
        -- =====================================================================
        channel_id    : in  std_logic_vector(4 downto 0);

        -- =====================================================================
        -- AXI4-Stream Slave Interface (Raw 500 kSPS Interleaved Stream)
        -- =====================================================================
        s_axis_tdata  : in  std_logic_vector(15 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;

        -- =====================================================================
        -- AXI4-Stream Master Interface (Decimated Interleaved Stream)
        -- =====================================================================
        m_axis_tdata  : out std_logic_vector(15 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic
    );
end axis_decimator;

architecture Behavioral of axis_decimator is

    -- Constant Channel Addresses in 7-Series XADC
    constant CH_VAUX1          : std_logic_vector(4 downto 0) := "10001"; -- 0x11 (Channel 1 / A0)
    constant CH_VAUX9          : std_logic_vector(4 downto 0) := "11001"; -- 0x19 (Channel 2 / A1)

    -- DSP48 20-bit Fixed-Point Reciprocal Constants: round(2^20 / M)
    constant K_RECIP_10        : unsigned(17 downto 0) := to_unsigned(104858, 18); -- 2^20 / 10
    constant K_RECIP_20        : unsigned(17 downto 0) := to_unsigned(52429, 18);  -- 2^20 / 20
    constant K_RECIP_50        : unsigned(17 downto 0) := to_unsigned(20972, 18);  -- 2^20 / 50

    -- Independent 24-bit Accumulators (Prevent overflow for up to M=50 sums)
    signal acc_ch1             : unsigned(23 downto 0) := (others => '0');
    signal acc_ch2             : unsigned(23 downto 0) := (others => '0');
    signal count_ch1           : integer range 0 to 50 := 0;
    signal count_ch2           : integer range 0 to 50 := 0;

    -- Edge detection for runtime profile switching
    signal decim_sel_prev      : std_logic_vector(1 downto 0) := "01";

    -- Output Emission Registers
    signal avg_ch1_reg         : std_logic_vector(15 downto 0) := (others => '0');
    signal avg_ch2_reg         : std_logic_vector(15 downto 0) := (others => '0');

    -- Pipelined State Machine (ST_CALC_AVG breaks the critical path)
    type t_out_state is (ST_ACCUMULATING, ST_CALC_AVG, ST_EMIT_CH1, ST_EMIT_CH2);
    signal out_state           : t_out_state := ST_ACCUMULATING;

begin

    s_axis_tready <= '1' when (out_state = ST_ACCUMULATING) else '0';

    m_axis_tdata <= avg_ch1_reg when (out_state = ST_EMIT_CH1) else
                    avg_ch2_reg when (out_state = ST_EMIT_CH2) else
                    (others => '0');

    m_axis_tvalid <= '1' when (out_state = ST_EMIT_CH1 or out_state = ST_EMIT_CH2) else '0';

    process(aclk)
        variable sample_val : unsigned(15 downto 0);
        variable is_ch1     : boolean;
        variable is_ch2     : boolean;
        variable m_target   : integer range 1 to 50;
        variable prod_ch1   : unsigned(41 downto 0);
        variable prod_ch2   : unsigned(41 downto 0);
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                acc_ch1        <= (others => '0');
                acc_ch2        <= (others => '0');
                count_ch1      <= 0;
                count_ch2      <= 0;
                avg_ch1_reg    <= (others => '0');
                avg_ch2_reg    <= (others => '0');
                decim_sel_prev <= decim_sel;
                out_state      <= ST_ACCUMULATING;
            else
                decim_sel_prev <= decim_sel;

                -- Synchronous flush on dynamic decimation mode switch
                if decim_sel /= decim_sel_prev then
                    acc_ch1     <= (others => '0');
                    acc_ch2     <= (others => '0');
                    count_ch1   <= 0;
                    count_ch2   <= 0;
                    out_state   <= ST_ACCUMULATING;
                else
                    -- Resolve active decimation target factor M
                    case decim_sel is
                        when "00"   => m_target := 1;   -- Bypass Mode (500 kSPS)
                        when "01"   => m_target := 10;  -- Full Audio (50 kSPS)
                        when "10"   => m_target := 20;  -- Speech / Vocal (25 kSPS)
                        when "11"   => m_target := 50;  -- Deep Bass Zoom (10 kSPS)
                        when others => m_target := 10;
                    end case;

                    case out_state is
                        -- ---------------------------------------------------------
                        -- 1. ACCUMULATE SAMPLES (FAST LOCAL ADDER: ~2.5 ns)
                        -- ---------------------------------------------------------
                        when ST_ACCUMULATING =>
                            if s_axis_tvalid = '1' then
                                sample_val := unsigned(s_axis_tdata);
                                is_ch1     := (channel_id = CH_VAUX1);
                                is_ch2     := (channel_id = CH_VAUX9);

                                if is_ch1 then
                                    if count_ch1 < m_target then
                                        acc_ch1   <= acc_ch1 + sample_val;
                                        count_ch1 <= count_ch1 + 1;
                                    end if;
                                elsif is_ch2 then
                                    if count_ch2 < m_target then
                                        acc_ch2   <= acc_ch2 + sample_val;
                                        count_ch2 <= count_ch2 + 1;
                                    end if;
                                end if;

                                -- Transition to averaging stage on terminal sample
                                if (is_ch2 and count_ch1 = m_target and count_ch2 = m_target - 1) or
                                   (count_ch1 = m_target and count_ch2 = m_target) then
                                    out_state <= ST_CALC_AVG;
                                end if;
                            end if;

                        -- ---------------------------------------------------------
                        -- 2. DSP48-ACCELERATED AVERAGING (REPLACES 20-LEVEL DIVIDER)
                        -- ---------------------------------------------------------
                        when ST_CALC_AVG =>
                            case decim_sel is
                                when "00" => -- M = 1 (Bypass)
                                    avg_ch1_reg <= std_logic_vector(acc_ch1(15 downto 0));
                                    avg_ch2_reg <= std_logic_vector(acc_ch2(15 downto 0));

                                when "01" => -- M = 10: (acc * 104858) >> 20
                                    prod_ch1 := acc_ch1 * K_RECIP_10;
                                    prod_ch2 := acc_ch2 * K_RECIP_10;
                                    avg_ch1_reg <= std_logic_vector(prod_ch1(35 downto 20));
                                    avg_ch2_reg <= std_logic_vector(prod_ch2(35 downto 20));

                                when "10" => -- M = 20: (acc * 52429) >> 20
                                    prod_ch1 := acc_ch1 * K_RECIP_20;
                                    prod_ch2 := acc_ch2 * K_RECIP_20;
                                    avg_ch1_reg <= std_logic_vector(prod_ch1(35 downto 20));
                                    avg_ch2_reg <= std_logic_vector(prod_ch2(35 downto 20));

                                when "11" => -- M = 50: (acc * 20972) >> 20
                                    prod_ch1 := acc_ch1 * K_RECIP_50;
                                    prod_ch2 := acc_ch2 * K_RECIP_50;
                                    avg_ch1_reg <= std_logic_vector(prod_ch1(35 downto 20));
                                    avg_ch2_reg <= std_logic_vector(prod_ch2(35 downto 20));

                                when others =>
                                    prod_ch1 := acc_ch1 * K_RECIP_10;
                                    prod_ch2 := acc_ch2 * K_RECIP_10;
                                    avg_ch1_reg <= std_logic_vector(prod_ch1(35 downto 20));
                                    avg_ch2_reg <= std_logic_vector(prod_ch2(35 downto 20));
                            end case;

                            -- Reset accumulators for next frame
                            acc_ch1   <= (others => '0');
                            acc_ch2   <= (others => '0');
                            count_ch1 <= 0;
                            count_ch2 <= 0;

                            out_state <= ST_EMIT_CH1;

                        -- ---------------------------------------------------------
                        -- 3. EMIT CHANNEL 1 (A0) FIRST (PHASE-LOCKED)
                        -- ---------------------------------------------------------
                        when ST_EMIT_CH1 =>
                            if m_axis_tready = '1' then
                                out_state <= ST_EMIT_CH2;
                            end if;

                        -- ---------------------------------------------------------
                        -- 4. EMIT CHANNEL 2 (A1) SECOND
                        -- ---------------------------------------------------------
                        when ST_EMIT_CH2 =>
                            if m_axis_tready = '1' then
                                out_state <= ST_ACCUMULATING;
                            end if;

                    end case;
                end if;
            end if;
        end if;
    end process;

end Behavioral;