library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tlast_generator is
    generic (
        PACKET_SIZE : integer := 1024  -- Number of samples per DMA transfer
    );
    port (
        aclk          : in  std_logic;
        aresetn       : in  std_logic;
        
        -- Slave Interface (from XADC)
        s_axis_tdata  : in  std_logic_vector(15 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        
        -- Master Interface (to DMA)
        m_axis_tdata  : out std_logic_vector(15 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;
        m_axis_tlast  : out std_logic
    );
end tlast_generator;

architecture Behavioral of tlast_generator is
    signal count_reg : integer range 0 to PACKET_SIZE - 1 := 0;
begin
    -- Direct pass-through for streaming data and handshakes
    s_axis_tready <= m_axis_tready;
    m_axis_tdata  <= s_axis_tdata;
    m_axis_tvalid <= s_axis_tvalid;

    -- Assert TLAST combinational output on the final sample of the packet
    m_axis_tlast <= '1' when (count_reg = PACKET_SIZE - 1) and (s_axis_tvalid = '1') and (m_axis_tready = '1') else '0';

    -- Synchronous process to increment the sample counter
    process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                count_reg <= 0;
            else
                if (s_axis_tvalid = '1') and (m_axis_tready = '1') then
                    if count_reg = PACKET_SIZE - 1 then
                        count_reg <= 0;
                    else
                        count_reg <= count_reg + 1;
                    end if; -- Closes: if count_reg = ...
                end if;     -- Closes: if (s_axis_tvalid = ...
            end if;         -- Closes: if aresetn = ...
        end if;             -- Closes: if rising_edge(aclk) ...
    end process;

end Behavioral;