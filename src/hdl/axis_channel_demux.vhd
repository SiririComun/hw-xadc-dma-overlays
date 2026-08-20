-- =============================================================================
-- File: axis_channel_demux.vhd
-- Description: AXI4-Stream Channel Demultiplexer & Single-Channel Filter.
--              Filters interleaved dual-channel stream (A0, A1, A0, A1...) and
--              emits a pure single-channel continuous stream with aligned TLAST.
--              sel_ch: '0' => Emit Channel 1 (A0)
--                      '1' => Emit Channel 2 (A1)
-- =============================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity axis_channel_demux is
    port (
        aclk          : in  std_logic;
        aresetn       : in  std_logic;

        -- Channel selector (0 = Channel 1 / A0, 1 = Channel 2 / A1)
        sel_ch        : in  std_logic;

        -- AXI4-Stream Slave Interface (Interleaved Input from Broadcaster)
        s_axis_tdata  : in  std_logic_vector(15 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tlast  : in  std_logic;

        -- AXI4-Stream Master Interface (Filtered Output to Subset Converter / FFT)
        m_axis_tdata  : out std_logic_vector(15 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;
        m_axis_tlast  : out std_logic
    );
end axis_channel_demux;

architecture Behavioral of axis_channel_demux is

    type t_state is (ST_WAIT_CH1, ST_EMIT);
    signal state      : t_state := ST_WAIT_CH1;

    signal ch1_reg    : std_logic_vector(15 downto 0) := (others => '0');
    signal ch2_reg    : std_logic_vector(15 downto 0) := (others => '0');
    signal tlast_reg  : std_logic := '0';

begin

    -- Stream Ready to upstream: accept Ch1 immediately, wait for downstream ready on Ch2
    s_axis_tready <= '1' when (state = ST_WAIT_CH1) else m_axis_tready;

    -- Stream Master Outputs
    m_axis_tdata  <= ch1_reg when (sel_ch = '0') else ch2_reg;
    m_axis_tlast  <= tlast_reg;
    m_axis_tvalid <= '1' when (state = ST_EMIT and s_axis_tvalid = '1') else '0';

    process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                state     <= ST_WAIT_CH1;
                ch1_reg   <= (others => '0');
                ch2_reg   <= (others => '0');
                tlast_reg <= '0';
            else
                case state is
                    -- Beat 1: Capture Channel 1 (A0) sample
                    when ST_WAIT_CH1 =>
                        if s_axis_tvalid = '1' then
                            ch1_reg <= s_axis_tdata;
                            state   <= ST_EMIT;
                        end if;

                    -- Beat 2: Capture Channel 2 (A1) sample & emit the selected channel
                    when ST_EMIT =>
                        if s_axis_tvalid = '1' then
                            ch2_reg   <= s_axis_tdata;
                            tlast_reg <= s_axis_tlast;

                            if m_axis_tready = '1' then
                                state <= ST_WAIT_CH1;
                            end if;
                        end if;
                end case;
            end if;
        end if;
    end process;

end Behavioral;