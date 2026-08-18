-- =============================================================================
-- File: axis_decimator.vhd
-- Description: Dual-Channel Interleaved AXI4-Stream Anti-Aliasing Decimator
--              Phase-locked to physical XADC channel_id (0x11 = A0, 0x19 = A1)
--              to prevent channel swapping across frames.
-- =============================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity axis_decimator is
    generic (
        DECIMATION_FACTOR : integer := 10 -- Decimation ratio M (500 kSPS / 10 = 50 kSPS)
    );
    port (
        aclk          : in  std_logic;
        aresetn       : in  std_logic;

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
        -- AXI4-Stream Master Interface (Decimated 50 kSPS Interleaved Stream)
        -- =====================================================================
        m_axis_tdata  : out std_logic_vector(15 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic
    );
end axis_decimator;

architecture Behavioral of axis_decimator is

    -- Constant Channel Addresses in 7-Series XADC
    constant CH_VAUX1       : std_logic_vector(4 downto 0) := "10001"; -- 0x11 (Channel 1 / A0)
    constant CH_VAUX9       : std_logic_vector(4 downto 0) := "11001"; -- 0x19 (Channel 2 / A1)

    -- Independent Accumulators
    signal acc_ch1          : unsigned(23 downto 0) := (others => '0');
    signal acc_ch2          : unsigned(23 downto 0) := (others => '0');
    signal count_ch1        : integer range 0 to DECIMATION_FACTOR := 0;
    signal count_ch2        : integer range 0 to DECIMATION_FACTOR := 0;

    -- Output Emission Registers
    signal avg_ch1_reg      : std_logic_vector(15 downto 0) := (others => '0');
    signal avg_ch2_reg      : std_logic_vector(15 downto 0) := (others => '0');

    -- Output State Machine
    type t_out_state is (ST_ACCUMULATING, ST_EMIT_CH1, ST_EMIT_CH2);
    signal out_state        : t_out_state := ST_ACCUMULATING;

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
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                acc_ch1       <= (others => '0');
                acc_ch2       <= (others => '0');
                count_ch1     <= 0;
                count_ch2     <= 0;
                avg_ch1_reg   <= (others => '0');
                avg_ch2_reg   <= (others => '0');
                out_state     <= ST_ACCUMULATING;
            else
                case out_state is
                    -- ---------------------------------------------------------
                    -- 1. ACCUMULATE SAMPLES DETERMINISTICALLY BY CHANNEL_ID
                    -- ---------------------------------------------------------
                    when ST_ACCUMULATING =>
                        if s_axis_tvalid = '1' then
                            sample_val := unsigned(s_axis_tdata);
                            is_ch1     := (channel_id = CH_VAUX1);
                            is_ch2     := (channel_id = CH_VAUX9);

                            if is_ch1 then
                                if count_ch1 < DECIMATION_FACTOR then
                                    acc_ch1   <= acc_ch1 + sample_val;
                                    count_ch1 <= count_ch1 + 1;
                                end if;
                            elsif is_ch2 then
                                if count_ch2 < DECIMATION_FACTOR then
                                    acc_ch2   <= acc_ch2 + sample_val;
                                    count_ch2 <= count_ch2 + 1;
                                end if;
                            end if;

                            -- When both channels have gathered M samples, emit pair
                            if (is_ch2 and count_ch1 = DECIMATION_FACTOR and count_ch2 = DECIMATION_FACTOR - 1) or
                               (count_ch1 = DECIMATION_FACTOR and count_ch2 = DECIMATION_FACTOR) then
                                
                                if is_ch2 then
                                    avg_ch2_reg <= std_logic_vector(resize((acc_ch2 + sample_val) / DECIMATION_FACTOR, 16));
                                else
                                    avg_ch2_reg <= std_logic_vector(resize(acc_ch2 / DECIMATION_FACTOR, 16));
                                end if;

                                avg_ch1_reg <= std_logic_vector(resize(acc_ch1 / DECIMATION_FACTOR, 16));
                                
                                -- Reset accumulators
                                acc_ch1     <= (others => '0');
                                acc_ch2     <= (others => '0');
                                count_ch1   <= 0;
                                count_ch2   <= 0;

                                out_state   <= ST_EMIT_CH1;
                            end if;
                        end if;

                    -- ---------------------------------------------------------
                    -- 2. EMIT CHANNEL 1 (A0) FIRST (GUARANTEED PHASE ORDER)
                    -- ---------------------------------------------------------
                    when ST_EMIT_CH1 =>
                        if m_axis_tready = '1' then
                            out_state <= ST_EMIT_CH2;
                        end if;

                    -- ---------------------------------------------------------
                    -- 3. EMIT CHANNEL 2 (A1) SECOND
                    -- ---------------------------------------------------------
                    when ST_EMIT_CH2 =>
                        if m_axis_tready = '1' then
                            out_state <= ST_ACCUMULATING;
                        end if;

                end case;
            end if;
        end if;
    end process;

end Behavioral;