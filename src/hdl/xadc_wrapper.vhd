-- ==============================================================================
-- Dual-Channel XADC Top-Level Wrapper (Hog Managed)
-- ==============================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
library UNISIM;
use UNISIM.VCOMPONENTS.ALL;

entity xadc_wrapper is
  generic (
    -- Hog-specific versioning generics
    GLOBAL_DATE         : std_logic_vector(31 downto 0) := x"00000000";
    GLOBAL_TIME         : std_logic_vector(31 downto 0) := x"00000000";
    GLOBAL_VER          : std_logic_vector(31 downto 0) := x"00000000";
    GLOBAL_SHA          : std_logic_vector(31 downto 0) := x"00000000";
    TOP_SHA             : std_logic_vector(31 downto 0) := x"00000000";
    TOP_VER             : std_logic_vector(31 downto 0) := x"00000000";
    HOG_SHA             : std_logic_vector(31 downto 0) := x"00000000";
    HOG_VER             : std_logic_vector(31 downto 0) := x"00000000";
    CON_VER             : std_logic_vector(31 downto 0) := x"00000000";
    CON_SHA             : std_logic_vector(31 downto 0) := x"00000000";
    XIL_DEFAULTLIB_VER  : std_logic_vector(31 downto 0) := x"00000000";
    XIL_DEFAULTLIB_SHA  : std_logic_vector(31 downto 0) := x"00000000";
    IPS_VER             : std_logic_vector(31 downto 0) := x"00000000";
    IPS_SHA             : std_logic_vector(31 downto 0) := x"00000000";
    OTHERS_VER          : std_logic_vector(31 downto 0) := x"00000000";
    OTHERS_SHA          : std_logic_vector(31 downto 0) := x"00000000"
  );
  port (
    DDR_addr    : inout STD_LOGIC_VECTOR ( 14 downto 0 );
    DDR_ba      : inout STD_LOGIC_VECTOR ( 2 downto 0 );
    DDR_cas_n   : inout STD_LOGIC;
    DDR_ck_n    : inout STD_LOGIC;
    DDR_ck_p    : inout STD_LOGIC;
    DDR_cke     : inout STD_LOGIC;
    DDR_cs_n    : inout STD_LOGIC;
    DDR_dm      : inout STD_LOGIC_VECTOR ( 3 downto 0 );
    DDR_dq      : inout STD_LOGIC_VECTOR ( 31 downto 0 );
    DDR_dqs_n   : inout STD_LOGIC_VECTOR ( 3 downto 0 );
    DDR_dqs_p   : inout STD_LOGIC_VECTOR ( 3 downto 0 );
    DDR_odt     : inout STD_LOGIC;
    DDR_ras_n   : inout STD_LOGIC;
    DDR_reset_n : inout STD_LOGIC;
    DDR_we_n    : inout STD_LOGIC;
    FIXED_IO_ddr_vrn : inout STD_LOGIC;
    FIXED_IO_ddr_vrp : inout STD_LOGIC;
    FIXED_IO_mio     : inout STD_LOGIC_VECTOR ( 53 downto 0 );
    FIXED_IO_ps_clk  : inout STD_LOGIC;
    FIXED_IO_ps_porb : inout STD_LOGIC;
    FIXED_IO_ps_srstb: inout STD_LOGIC;
    
    -- Channel 1 (A0 - Vaux1)
    Vaux1_0_v_n : in STD_LOGIC;
    Vaux1_0_v_p : in STD_LOGIC;
    
    -- Channel 2 (A1 - Vaux9)
    Vaux9_0_v_n : in STD_LOGIC;
    Vaux9_0_v_p : in STD_LOGIC;
    
    -- Dedicated Vp/Vn Header
    Vp_Vn_0_v_n : in STD_LOGIC;
    Vp_Vn_0_v_p : in STD_LOGIC
  );
end xadc_wrapper;

architecture STRUCTURE of xadc_wrapper is
  component xadc is
  port (
    DDR_cas_n   : inout STD_LOGIC;
    DDR_cke     : inout STD_LOGIC;
    DDR_ck_n    : inout STD_LOGIC;
    DDR_ck_p    : inout STD_LOGIC;
    DDR_cs_n    : inout STD_LOGIC;
    DDR_reset_n : inout STD_LOGIC;
    DDR_odt     : inout STD_LOGIC;
    DDR_ras_n   : inout STD_LOGIC;
    DDR_we_n    : inout STD_LOGIC;
    DDR_ba      : inout STD_LOGIC_VECTOR ( 2 downto 0 );
    DDR_addr    : inout STD_LOGIC_VECTOR ( 14 downto 0 );
    DDR_dm      : inout STD_LOGIC_VECTOR ( 3 downto 0 );
    DDR_dq      : inout STD_LOGIC_VECTOR ( 31 downto 0 );
    DDR_dqs_n   : inout STD_LOGIC_VECTOR ( 3 downto 0 );
    DDR_dqs_p   : inout STD_LOGIC_VECTOR ( 3 downto 0 );
    FIXED_IO_mio     : inout STD_LOGIC_VECTOR ( 53 downto 0 );
    FIXED_IO_ddr_vrn : inout STD_LOGIC;
    FIXED_IO_ddr_vrp : inout STD_LOGIC;
    FIXED_IO_ps_srstb: inout STD_LOGIC;
    FIXED_IO_ps_clk  : inout STD_LOGIC;
    FIXED_IO_ps_porb : inout STD_LOGIC;
    Vaux1_0_v_n : in STD_LOGIC;
    Vaux1_0_v_p : in STD_LOGIC;
    Vaux9_0_v_n : in STD_LOGIC;
    Vaux9_0_v_p : in STD_LOGIC;
    Vp_Vn_0_v_n : in STD_LOGIC;
    Vp_Vn_0_v_p : in STD_LOGIC
  );
  end component xadc;
begin
xadc_i: component xadc
     port map (
      DDR_addr(14 downto 0) => DDR_addr(14 downto 0),
      DDR_ba(2 downto 0)    => DDR_ba(2 downto 0),
      DDR_cas_n             => DDR_cas_n,
      DDR_ck_n              => DDR_ck_n,
      DDR_ck_p              => DDR_ck_p,
      DDR_cke               => DDR_cke,
      DDR_cs_n              => DDR_cs_n,
      DDR_dm(3 downto 0)    => DDR_dm(3 downto 0),
      DDR_dq(31 downto 0)   => DDR_dq(31 downto 0),
      DDR_dqs_n(3 downto 0) => DDR_dqs_n(3 downto 0),
      DDR_dqs_p(3 downto 0) => DDR_dqs_p(3 downto 0),
      DDR_odt               => DDR_odt,
      DDR_ras_n             => DDR_ras_n,
      DDR_reset_n           => DDR_reset_n,
      DDR_we_n              => DDR_we_n,
      FIXED_IO_ddr_vrn      => FIXED_IO_ddr_vrn,
      FIXED_IO_ddr_vrp      => FIXED_IO_ddr_vrp,
      FIXED_IO_mio(53 downto 0) => FIXED_IO_mio(53 downto 0),
      FIXED_IO_ps_clk       => FIXED_IO_ps_clk,
      FIXED_IO_ps_porb      => FIXED_IO_ps_porb,
      FIXED_IO_ps_srstb     => FIXED_IO_ps_srstb,
      Vaux1_0_v_n           => Vaux1_0_v_n,
      Vaux1_0_v_p           => Vaux1_0_v_p,
      Vaux9_0_v_n           => Vaux9_0_v_n,
      Vaux9_0_v_p           => Vaux9_0_v_p,
      Vp_Vn_0_v_n           => Vp_Vn_0_v_n,
      Vp_Vn_0_v_p           => Vp_Vn_0_v_p
    );
end STRUCTURE;