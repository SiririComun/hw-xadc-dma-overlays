-- =============================================================================
-- File: axis_spectral_mask.vhd
-- Description: Hardware Frequency-Domain Spectral Masking & Filter Core.
--              Operates on 32-bit complex FFT streams ({Im[15:0], Re[15:0]}).
--              Implements real-signal Hermitian symmetry: k_eff = min(k, N - k)
--              to achieve full 1:1 amplitude fidelity and >40 dB stopband rejection.
-- =============================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity axis_spectral_mask is
    generic (
        C_S_AXI_DATA_WIDTH : integer := 32;
        C_S_AXI_ADDR_WIDTH : integer := 5
    );
    port (
        aclk          : in  std_logic;
        aresetn       : in  std_logic;

        -- =====================================================================
        -- AXI4-Lite Slave Interface (Filter Control & Cutoff Registers)
        -- =====================================================================
        s_axi_awaddr  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH - 1 downto 0);
        s_axi_awprot  : in  std_logic_vector(2 downto 0);
        s_axi_awvalid : in  std_logic;
        s_axi_awready : out std_logic;
        s_axi_wdata   : in  std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
        s_axi_wstrb   : in  std_logic_vector((C_S_AXI_DATA_WIDTH / 8) - 1 downto 0);
        s_axi_wvalid  : in  std_logic;
        s_axi_wready  : out std_logic;
        s_axi_bresp   : out std_logic_vector(1 downto 0);
        s_axi_bvalid  : out std_logic;
        s_axi_bready  : in  std_logic;
        s_axi_araddr  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH - 1 downto 0);
        s_axi_arprot  : in  std_logic_vector(2 downto 0);
        s_axi_arvalid : in  std_logic;
        s_axi_arready : out std_logic;
        s_axi_rdata   : out std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
        s_axi_rresp   : out std_logic_vector(1 downto 0);
        s_axi_rvalid  : out std_logic;
        s_axi_rready  : in  std_logic;

        -- =====================================================================
        -- AXI4-Stream Slave Interface (Complex Spectrum from xfft_0)
        -- =====================================================================
        s_axis_tdata  : in  std_logic_vector(31 downto 0); -- {Im[15:0], Re[15:0]}
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tlast  : in  std_logic;

        -- =====================================================================
        -- AXI4-Stream Master Interface (Masked Complex Spectrum to xfft_1)
        -- =====================================================================
        m_axis_tdata  : out std_logic_vector(31 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;
        m_axis_tlast  : out std_logic
    );
end axis_spectral_mask;

architecture Behavioral of axis_spectral_mask is

    -- Register Offsets (Byte-addressed via s_axi_awaddr[4:2])
    -- 0x00: REG_CTRL      [0]: Filter Enable (0=Bypass, 1=Enable)
    --                     [2:1]: Mode (00=Lowpass/Bass, 01=Highpass, 10=Bandpass, 11=Notch)
    -- 0x04: REG_BIN_START [15:0] Lower Cutoff Bin (k_start)
    -- 0x08: REG_BIN_STOP  [15:0] Upper Cutoff Bin (k_stop)
    -- 0x0C: REG_FFT_LEN   [15:0] FFT Transform Length N (Default: 1024)
    -- 0x10: REG_STATUS    [0]: Frame Active, [31:16]: Current Bin Count
    signal reg_ctrl      : std_logic_vector(31 downto 0) := (others => '0'); -- Default: Bypass
    signal reg_bin_start : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_bin_stop  : std_logic_vector(31 downto 0) := x"0000000A";     -- Default: Bin 10
    signal reg_fft_len   : std_logic_vector(31 downto 0) := x"00000400";     -- Default: N = 1024
    signal reg_status    : std_logic_vector(31 downto 0) := (others => '0');

    -- AXI Handshake Signals
    signal axi_awready   : std_logic := '0';
    signal axi_wready    : std_logic := '0';
    signal axi_bvalid    : std_logic := '0';
    signal axi_arready   : std_logic := '0';
    signal axi_rvalid    : std_logic := '0';
    signal axi_rdata     : std_logic_vector(31 downto 0) := (others => '0');

    -- Frequency Bin Tracking
    signal bin_count     : unsigned(15 downto 0) := (others => '0');
    signal frame_active  : std_logic := '0';
    signal reg_sync_rst  : std_logic := '0';

    -- Filter Aliases
    signal filter_en     : std_logic;
    signal filter_mode   : std_logic_vector(1 downto 0);

begin

    filter_en   <= reg_ctrl(0);
    filter_mode <= reg_ctrl(2 downto 1);

    -- Status register mapping
    reg_status(0)           <= frame_active;
    reg_status(15 downto 1) <= (others => '0');
    reg_status(31 downto 16)<= std_logic_vector(bin_count);

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
                axi_awready   <= '0';
                axi_wready    <= '0';
                axi_bvalid    <= '0';
                reg_ctrl      <= (others => '0'); -- Default: Bypass
                reg_bin_start <= (others => '0');
                reg_bin_stop  <= x"0000000A";     -- Default: Bin 10
                reg_fft_len   <= x"00000400";     -- Default: N = 1024
                reg_sync_rst  <= '0';
            else
                reg_sync_rst <= '0';

                if (axi_awready = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1') then
                    axi_awready <= '1';
                    axi_wready  <= '1';
                else
                    axi_awready <= '0';
                    axi_wready  <= '0';
                end if;

                if (axi_awready = '1' and axi_wready = '1') then
                    write_addr := to_integer(unsigned(s_axi_awaddr(4 downto 2)));
                    reg_sync_rst <= '1'; -- Synchronous flush on register write to prevent phase drift!
                    case write_addr is
                        when 0 => reg_ctrl      <= s_axi_wdata; -- 0x00
                        when 1 => reg_bin_start <= s_axi_wdata; -- 0x04
                        when 2 => reg_bin_stop  <= s_axi_wdata; -- 0x08
                        when 3 => reg_fft_len   <= s_axi_wdata; -- 0x0C
                        when others => null;
                    end case;
                end if;

                if (axi_awready = '1' and axi_wready = '1' and axi_bvalid = '0') then
                    axi_bvalid <= '1';
                elsif (s_axi_bready = '1' and axi_bvalid = '1') then
                    axi_bvalid <= '0';
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
                        when 1 => axi_rdata <= reg_bin_start;
                        when 2 => axi_rdata <= reg_bin_stop;
                        when 3 => axi_rdata <= reg_fft_len;
                        when 4 => axi_rdata <= reg_status;
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
    -- 2. AXI4-Stream Hermitian Symmetric Masking Engine
    -- =========================================================================
    s_axis_tready <= m_axis_tready;
    m_axis_tvalid <= s_axis_tvalid;
    m_axis_tlast  <= s_axis_tlast;

    -- Hermitian Symmetric Filter Process: k_eff = min(k, N - k)
    process(bin_count, reg_bin_start, reg_bin_stop, reg_fft_len, filter_en, filter_mode, s_axis_tdata)
        variable k_raw   : unsigned(15 downto 0);
        variable n_len   : unsigned(15 downto 0);
        variable k_eff   : unsigned(15 downto 0);
        variable k_start : unsigned(15 downto 0);
        variable k_stop  : unsigned(15 downto 0);
        variable pass    : boolean;
    begin
        k_raw   := bin_count;
        n_len   := unsigned(reg_fft_len(15 downto 0));
        k_start := unsigned(reg_bin_start(15 downto 0));
        k_stop  := unsigned(reg_bin_stop(15 downto 0));

        -- Calculate Hermitian Effective Frequency Bin: k_eff = min(k, N - k)
        if (k_raw <= shift_right(n_len, 1)) then
            k_eff := k_raw;
        else
            k_eff := n_len - k_raw;
        end if;

        if filter_en = '0' then
            pass := true; -- Bypass mode: pass all frequencies
        else
            case filter_mode is
                when "00" => -- Lowpass / Bass: Pass k_eff <= k_stop
                    pass := (k_eff <= k_stop);

                when "01" => -- Highpass / Treble: Pass k_eff >= k_start
                    pass := (k_eff >= k_start);

                when "10" => -- Bandpass: Pass k_start <= k_eff <= k_stop
                    pass := (k_eff >= k_start and k_eff <= k_stop);

                when "11" => -- Notch / Bandstop: Zero out k_start <= k_eff <= k_stop
                    pass := not (k_eff >= k_start and k_eff <= k_stop);

                when others =>
                    pass := true;
            end case;
        end if;

        if pass then
            m_axis_tdata <= s_axis_tdata; -- Pass original complex word {Im, Re}
        else
            m_axis_tdata <= (others => '0'); -- Zero out both Real and Imaginary
        end if;
    end process;

    -- Bin Counter Synchronization
    process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' or reg_sync_rst = '1' then
                bin_count    <= (others => '0');
                frame_active <= '0';
            else
                if (s_axis_tvalid = '1' and m_axis_tready = '1') then
                    frame_active <= '1';

                    if s_axis_tlast = '1' then
                        bin_count    <= (others => '0'); -- Reset on frame boundary
                        frame_active <= '0';
                    else
                        bin_count    <= bin_count + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

end Behavioral;