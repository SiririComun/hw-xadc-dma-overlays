-- =============================================================================
-- File: tlast_generator.vhd
-- Description: Runtime-Programmable AXI4-Stream Packetizer & TLAST Generator.
--              Asserts TLAST on the final sample of a frame defined by
--              packet_size_in (driven by axis_trigger_unit register 0x1C).
-- =============================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tlast_generator is
    generic (
        DEFAULT_PACKET_SIZE : integer := 2048
    );
    port (
        aclk            : in  std_logic;
        aresetn         : in  std_logic;

        -- =====================================================================
        -- Runtime Packet Size Input (from axis_trigger_unit register 0x1C)
        -- =====================================================================
        packet_size_in  : in  std_logic_vector(15 downto 0);

        -- =====================================================================
        -- AXI4-Stream Slave Interface (from Decimator)
        -- =====================================================================
        s_axis_tdata    : in  std_logic_vector(15 downto 0);
        s_axis_tvalid   : in  std_logic;
        s_axis_tready   : out std_logic;

        -- =====================================================================
        -- AXI4-Stream Master Interface (to Broadcaster / DMA)
        -- =====================================================================
        m_axis_tdata    : out std_logic_vector(15 downto 0);
        m_axis_tvalid   : out std_logic;
        m_axis_tready   : in  std_logic;
        m_axis_tlast    : out std_logic
    );
end tlast_generator;

architecture Behavioral of tlast_generator is
    signal count_reg    : unsigned(15 downto 0) := (others => '0');
    signal target_limit : unsigned(15 downto 0);
begin
    -- Direct pass-through for stream data and handshakes
    s_axis_tready <= m_axis_tready;
    m_axis_tdata  <= s_axis_tdata;
    m_axis_tvalid <= s_axis_tvalid;

    -- Dynamic target boundary calculation (target_limit = packet_size - 1)
    target_limit <= (unsigned(packet_size_in) - 1) when (unsigned(packet_size_in) > 0) else
                    to_unsigned(DEFAULT_PACKET_SIZE - 1, 16);

    -- Assert TLAST combinational output on the final sample of the packet
    m_axis_tlast <= '1' when (count_reg = target_limit) and (s_axis_tvalid = '1') and (m_axis_tready = '1') else '0';

    process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                count_reg <= (others => '0');
            else
                if (s_axis_tvalid = '1') and (m_axis_tready = '1') then
                    if count_reg >= target_limit then
                        count_reg <= (others => '0');
                    else
                        count_reg <= count_reg + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

end Behavioral;