-- =============================================================================
-- File: axis_channel_demux.vhd
-- Description: AXI4-Stream Channel Demultiplexer & Single-Channel Filter.
--              Filters interleaved dual-channel stream (A0, A1, A0, A1...) and
--              emits a pure single-channel continuous stream with concurrent TLAST.
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

    type t_state is (ST_WAIT_CH1, ST_EMIT_CH2);
    signal state       : t_state := ST_WAIT_CH1;

    signal ch1_reg     : std_logic_vector(15 downto 0) := (others => '0');
    signal tlast_latch : std_logic := '0';

begin

    -- Upstream Handshake:
    -- Beat 1 (CH1): Ready to capture CH1 sample
    -- Beat 2 (CH2): Ready only when downstream (FFT) accepts the emitted sample
    s_axis_tready <= '1' when (state = ST_WAIT_CH1) else m_axis_tready;

    -- Master Outputs:
    m_axis_tdata  <= ch1_reg when (sel_ch = '0') else s_axis_tdata;
    m_axis_tlast  <= s_axis_tlast or tlast_latch;
    m_axis_tvalid <= '1' when (state = ST_EMIT_CH2 and s_axis_tvalid = '1') else '0';

    process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                state       <= ST_WAIT_CH1;
                ch1_reg     <= (others => '0');
                tlast_latch <= '0';
            else
                case state is
                    -- Beat 1: Capture CH1 sample ONLY on valid handshake
                    when ST_WAIT_CH1 =>
                        if (s_axis_tvalid = '1') then
                            ch1_reg     <= s_axis_tdata;
                            tlast_latch <= s_axis_tlast;
                            state       <= ST_EMIT_CH2;
                        end if;

                    -- Beat 2: Emit selected channel and advance ONLY when downstream handshakes
                    when ST_EMIT_CH2 =>
                        if (s_axis_tvalid = '1' and m_axis_tready = '1') then
                            tlast_latch <= '0';
                            state       <= ST_WAIT_CH1;
                        end if;
                end case;

                -- Self-healing Frame Sync: Always reset to Beat 1 on packet end
                if (s_axis_tvalid = '1' and s_axis_tlast = '1' and m_axis_tready = '1') then
                    state       <= ST_WAIT_CH1;
                    tlast_latch <= '0';
                end if;
            end if;
        end if;
    end process;

end Behavioral;