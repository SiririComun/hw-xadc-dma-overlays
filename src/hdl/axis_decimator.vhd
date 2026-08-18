-- =============================================================================
-- File: axis_decimator.vhd
-- Description: Dual-Channel Interleaved AXI4-Stream Anti-Aliasing Decimator
--              Accumulates and averages M consecutive samples per channel
--              (500 kSPS -> 50 kSPS per channel for M = 10).
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

    -- Channel Tracking for Interleaved Stream (0 = Channel 1 / A0, 1 = Channel 2 / A1)
    signal ch_in_toggle     : std_logic := '0';

    -- Independent Accumulators (24-bit to prevent overflow on summing 16-bit samples)
    signal acc_ch1          : unsigned(23 downto 0) := (others => '0');
    signal acc_ch2          : unsigned(23 downto 0) := (others => '0');
    signal count_ch1        : integer range 0 to DECIMATION_FACTOR := 0;
    signal count_ch2        : integer range 0 to DECIMATION_FACTOR := 0;

    -- Output Emission Registers
    signal avg_ch1_reg      : std_logic_vector(15 downto 0) := (others => '0');
    signal avg_ch2_reg      : std_logic_vector(15 downto 0) := (others => '0');

    -- Output State Machine (Emits decimated Ch1 then Ch2 sequentially)
    type t_out_state is (ST_ACCUMULATING, ST_EMIT_CH1, ST_EMIT_CH2);
    signal out_state        : t_out_state := ST_ACCUMULATING;

begin

    -- Accept input samples when not blocked by output emission
    s_axis_tready <= '1' when (out_state = ST_ACCUMULATING) else '0';

    -- Assign Master AXI-Stream signals based on output state
    m_axis_tdata <= avg_ch1_reg when (out_state = ST_EMIT_CH1) else
                    avg_ch2_reg when (out_state = ST_EMIT_CH2) else
                    (others => '0');

    m_axis_tvalid <= '1' when (out_state = ST_EMIT_CH1 or out_state = ST_EMIT_CH2) else '0';

    process(aclk)
        variable sample_val : unsigned(15 downto 0);
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                ch_in_toggle  <= '0';
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
                    -- 1. ACCUMULATE INCOMING RAW SAMPLES
                    -- ---------------------------------------------------------
                    when ST_ACCUMULATING =>
                        if s_axis_tvalid = '1' then
                            sample_val := unsigned(s_axis_tdata);

                            if ch_in_toggle = '0' then
                                -- Channel 1 (A0) Sample
                                acc_ch1      <= acc_ch1 + sample_val;
                                count_ch1    <= count_ch1 + 1;
                                ch_in_toggle <= '1';
                            else
                                -- Channel 2 (A1) Sample
                                acc_ch2      <= acc_ch2 + sample_val;
                                count_ch2    <= count_ch2 + 1;
                                ch_in_toggle <= '0';
                            end if;

                            -- When both channels reach M samples, compute average and emit
                            if (ch_in_toggle = '1') and (count_ch1 = DECIMATION_FACTOR) and (count_ch2 = DECIMATION_FACTOR - 1) then
                                -- Compute normalized average: sum / M
                                avg_ch1_reg <= std_logic_vector(resize(acc_ch1 / DECIMATION_FACTOR, 16));
                                avg_ch2_reg <= std_logic_vector(resize((acc_ch2 + sample_val) / DECIMATION_FACTOR, 16));
                                
                                -- Reset accumulators for next audio period
                                acc_ch1     <= (others => '0');
                                acc_ch2     <= (others => '0');
                                count_ch1   <= 0;
                                count_ch2   <= 0;

                                -- Transition to sequential output emission
                                out_state   <= ST_EMIT_CH1;
                            end if;
                        end if;

                    -- ---------------------------------------------------------
                    -- 2. EMIT DECIMATED CHANNEL 1 (A0)
                    -- ---------------------------------------------------------
                    when ST_EMIT_CH1 =>
                        if m_axis_tready = '1' then
                            out_state <= ST_EMIT_CH2;
                        end if;

                    -- ---------------------------------------------------------
                    -- 3. EMIT DECIMATED CHANNEL 2 (A1)
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