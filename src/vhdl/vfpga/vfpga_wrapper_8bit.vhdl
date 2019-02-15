
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity VFPGA_WRAPPER_8BIT is
  Port (
    -- MEGA65 fastio interface for control registers
    clock : in std_logic;       -- 40MHz fastio clock
    pixel_clock : in std_logic; -- vFPGA originally expected 100MHz here. We
    -- instead are using 80MHz on MEGA65
    cs_vfpga : in std_logic;    -- chip select for this device on fastio bus

    -- Fastio memory interface
    fastio_read : in std_logic;
    fastio_write : in std_logic;
    fastio_address : in unsigned(27 downto 0);
    fastio_rdata : out unsigned(7 downto 0);
    fastio_wdata : in unsigned(7 downto 0);

    -- VFPGA external connections in case we want to plumb them into something,
    -- like a hardware multiplier
    VFPGA_CLK      : out std_logic;	
    INPUTS         : in  std_logic_vector(55 downto 0);
    OUTPUTS        : out std_logic_vector(55 downto 0));
end VFPGA_WRAPPER_8BIT;

architecture Behavioral of VFPGA_WRAPPER_8BIT is

  -- PGS 20190215: Make the specifications of the VFPGA visible
  constant WIDTH : integer := 8; -- width of CLB array
  constant HEIGHT : integer := 6;  -- height of CLB array
  constant N : integer := 4;  -- # luts per CLB, each of which have one output
  -- bit which is the snapshot state
  constant I : integer := 10; -- # of inputs per CLB, not important for
  -- saving/resuming state, only for bitstream compatibility)
  constant K : integer := 4;  -- # of inputs per LUT

  constant BITSTREAM_BITS : std_logic_vector(22 downto 0) := "00000000010110101101000";
  constant BITSTREAM_BYTES : integer := to_integer(unsigned(BITSTREAM_BITS))/8;
  constant SNAPSHOT_BYTES : integer := (WIDTH*HEIGHT*K)/8;
  constant NUM_IO : integer := 56;         

  signal vfpga_reset             : std_ulogic := '0';
  signal vfpga_vclock            : std_ulogic := '0';
  signal vFPGA_snap_save         : std_ulogic := '0';
  signal vFPGA_snap_restore      : std_ulogic := '0';
  signal vFPGA_snap_in           : std_ulogic_vector(31 downto 0) := (others => '0');
  signal vFPGA_snap_out          : std_ulogic_vector(31 downto 0) := (others => '0');
  signal vFPGA_snap_shift        : std_ulogic := '0';
  signal vFPGA_config_in         : std_ulogic_vector(31 downto 0) := (others => '0');
  signal vFPGA_config_valid      : std_ulogic := '0';  -- Rising edge causes
                                                       -- vFPGA_config_in to be
                                                       -- shifted into config,
                                                       -- and shifts previous
                                                       -- config out
  -- When shifing config in, we shift the old config out, so that we can
  -- recover the bitstream from a running unit when freezing
  signal vFPGA_config_out         : std_ulogic_vector(31 downto 0) := (others => '0');
  signal vFPGA_inputs            : std_ulogic_vector(55 downto 0) := (others => '0');
  signal vFPGA_outputs           : std_ulogic_vector(55 downto 0) := (others => '0');
  signal clk_done_IE             : std_logic := '0';

  signal vfpga_rest              : std_ulogic := '0';
  signal reg_clk_div             : std_ulogic_vector(9 downto 0) := (others => '0');
  signal reg_clk_cycle_counter   : std_ulogic_vector(23 downto 0) := (others => '0');

  signal clk_cycle_counter_valid : std_ulogic := '0';

  signal clk_cycle_counter_remainder : std_ulogic_vector(23 downto 0) := (others => '0');
  signal clk_cycle_counter_done  : std_ulogic := '0';

  signal global_interrupt        : std_ulogic := '0';
  signal global_interrupt_IE     : std_ulogic := '0';

  signal write_config            : std_ulogic := '0';
  signal old_write_config        : std_ulogic := '0';

  signal write_snap_in           : std_ulogic := '0';
  signal read_snap_out           : std_ulogic := '0';
  signal old_write_snap_in       : std_ulogic := '0';
  signal old_read_snap_out       : std_ulogic := '0';

  signal write_snap_save         : std_ulogic := '0';
  signal write_snap_restore      : std_ulogic := '0';
  signal old_write_snap_save     : std_ulogic := '0';
  signal old_write_snap_restore  : std_ulogic := '0';

  signal write_clkcnt            : std_ulogic := '0';
  signal old_write_clkcnt        : std_ulogic := '0';

  signal snapshot_access_phase : integer range 0 to 3 := 0;
  signal config_access_phase : integer range 0 to 3 := 0;
  
begin

  -- Export divided vFPGA clock
  VFPGA_CLK      <= std_logic(vfpga_vclock);

  process (pixel_clock)
  begin
    if rising_edge(pixel_clock) then
      global_interrupt <= (clk_cycle_counter_done and clk_done_IE);
    end if;
  end process;


  vFPGA: entity work.ARCH8X6W16N4I10K4FCI4FCO8PFI8PFO8IOPB2_wrapper
    port map ( clk          => pixel_clock,
               rst          => vfpga_reset,               -- vFPGA runs if rst = 0
               clk_app      => vfpga_vclock,
               rst_app      => vfpga_reset,
               snap_save    => vFPGA_snap_save,
               snap_restore => vFPGA_snap_restore,
               config_out   => vFPGA_config_out,
               config_in    => vFPGA_config_in,       -- 32 bit config word
               config_valid => vFPGA_config_valid,    -- config word is
                                                      -- accepted if this line
                                                      -- is high
               snap_in      => vFPGA_snap_in,
               snap_out     => vFPGA_snap_out,
               snap_shift   => vFPGA_snap_shift,
               inputs       => vFPGA_inputs,
               outputs      => vFPGA_outputs);


  CLK_CTRL: entity work.vFPGA_clock_controller_pausable
    port map ( clk               => pixel_clock,
               -- The vFPGA stops when in the hypervisor, so that we can freeze
               -- things.  This is safe because the snapshotting of the FPGA state
               -- does not have a carry or shift chain, but rather has direct routing
               -- of the output bit of each LUT to the snapshot vector
               pause             => hypervisor_mode,
               rst               => vfpga_reset,
               clk_div           => reg_clk_div,
               clk_cont_in       => reg_clk_cycle_counter,
               clk_cont_in_valid => clk_cycle_counter_valid,
               continue_clk_app  => '0',
               clk_cont_out      => clk_cycle_counter_remainder,
               done              => clk_cycle_counter_done,
               clk_app           => vfpga_vclock);


  -- Read process --
  process(clock)
  begin
    if rising_edge(clock) then

      vFPGA_config_valid <= '0';
      vFPGA_snap_shift <= '0';
      
      fastio_rdata <= (others => 'Z');

      -- XXX: We need to support freezing even if the access phases
      -- for the bitstream or snapshot data are not 0
      -- This is a royal pain to actually do, as we need to expose
      -- the contents of the partially read/written words etc.
      -- For now, we are just going to ignore this, on the basis
      -- that freezing happens only rarely, and the probability of
      -- a sensible program leaving things in this state when a freeze
      -- occurs is low. We really should solve it in the long-term
      -- however, so that freezing is truly safe and exact.
      last_hypervisor_mode <= hypervisor_mode;
      if hypervisor_mode = '1' and last_hypervisor_mode='0' then
        -- XXX Read the above about how we should really do this better!
        config_access_phase <= 0;
        snapshot_access_phase <= 0;
      end if;
      
      if fastio_write='1' and cs_vfpga='1' then
        case fastio_address(7 downto 0) is
          when x"0b" =>
            vfpga_reset <= fastio_wdata(4);              
            clk_done_IE <= fastio_wdata(5);              
            global_interrupt_IE <= fastio_wdata(6);              
            global_interrupt <= fastio_wdata(7);              
          when x"15" =>
            -- Write a byte of the config
            case config_access_phase is
              when 0 => vfpga_config_in(7 downto 0) <= fastio_wdata;
              when 1 => vfpga_config_in(15 downto 8) <= fastio_wdata;
              when 2 => vfpga_config_in(23 downto 16) <= fastio_wdata;
              when 3 => vfpga_config_in(31 downto 24) <= fastio_wdata;
            end case;
            if config_access_phase = 3 then
              config_access_phase <= 0;
              vFPGA_config_valid <= '1';
            else
              config_access_phase <= config_access_phase + 1;
            end if;

          when x"16" =>
            -- Read a byte of the snapshot
            case snapshot_access_phase is
              when 0 => vfpga_snap_in(7 downto 0) <= fastio_wdata;
              when 1 => vfpga_snap_in(15 downto 8) <= fastio_wdata;
              when 2 => vfpga_snap_in(23 downto 16) <= fastio_wdata;
              when 3 => vfpga_snap_in(31 downto 24) <= fastio_wdata;
            end case;

            if snapshot_access_phase = 3 then
              snapshot_access_phase <= 0;
              -- Similar to the above
              vFPGA_snap_shift <= '1';
            else
              snapshot_access_phase <= snapshot_access_phase + 1;
            end if;
          when others => null;
        end case;
        
      end if;
      
      if fastio_read='1' and cs_vfpga='1' then
        case fastio_address(7 downto 0) is
          -- VFPGA characteristics

        -- @IO:GS $FFDF000 - VFPGA width of CLB array (READ ONLY)
        -- @IO:GS $FFDF001 - VFPGA height of CLB array (READ ONLY)
        -- @IO:GS $FFDF002 - VFPGA Logical wire cardinality (READ ONLY)
        -- @IO:GS $FFDF003 - VFPGA number of LUTs per CLB (READ ONLY)
        -- @IO:GS $FFDF004 - VFPGA number of inputs per CLB (READ ONLY)
        -- @IO:GS $FFDF005 - VFPGA number of inputs per LUT (READ ONLY)
        -- @IO:GS $FFDF006 - VFPGA number of IO pins (READ ONLY)
        -- @IO:GS $FFDF007 - VFPGA number of bytes in bitstream (LSB) (READ ONLY)
        -- @IO:GS $FFDF008 - VFPGA number of bytes in bitstream (MSB) (READ ONLY)
        -- @IO:GS $FFDF009 - VFPGA number of bytes in snapshot (LSB) (READ ONLY)
        -- @IO:GS $FFDF00A - VFPGA number of bytes in snapshot (MSB) (READ ONLY)
          
          when x"00" => fastio_rdata <= to_unsigned(WIDTH,8); -- width of VFPGA
          when x"01" => fastio_rdata <= to_unsigned(HEIGHT,8); -- height of VFPGA
          when x"02" => fastio_rdata <= to_unsigned(WIDTH/2,8); -- Logical wire cardinality (= W/2)
          when x"03" => fastio_rdata <= to_unsigned(N,8); -- N
          when x"04" => fastio_rdata <= to_unsigned(I,8); -- I
          when x"05" => fastio_rdata <= to_unsigned(K,8); -- K
          when x"06" => fastio_rdata <= to_unsigned(NUM_IO,8);
          when x"07" => fastio_rdata <= to_unsigned(BITSTREAM_BYTES,8);
          when x"08" => fastio_rdata <= to_unsigned(BITSTREAM_BYTES/256,8);
          when x"09" => fastio_rdata <= to_unsigned(SNAPSHOT_BYTES,8);
          when x"0a" => fastio_rdata <= to_unsigned(SNAPSHOT_BYTES/256,8);

        -- @IO:GS $FFDF00B.0 - VFPGA DMA engine present flag (READ ONLY)
        -- @IO:GS $FFDF00B.1 - VFPGA memory access engine present flag (READ ONLY)
        -- @IO:GS $FFDF00B.2 - VFPGA interrupt pin present flag (READ ONLY)
        -- @IO:GS $FFDF00B.3 - VFPGA cycle count done flag (READ ONLY)
        -- @IO:GS $FFDF00B.4 - VFPGA reset (1= VFPGA is held under reset)
        -- @IO:GS $FFDF00B.5 - VFPGA clk_done_IE flag
        -- @IO:GS $FFDF00B.6 - VFPGA global_interrupt_IE flag 
        -- @IO:GS $FFDF00B.7 - VFPGA global_interrupt flag (READ ONLY)
          when x"0b" =>
            fastio_rdata(0) <= '0'; -- With DMA ?
            fastio_rdata(1) <= '0'; -- With MEM access ?
            fastio_rdata(2) <= '0'; -- With interrupt pin ?
            fastio_rdata(3) <= clk_cycle_counter_done;
            fastio_rdata(4) <= vfpga_reset;
            fastio_rdata(5) <= clk_done_IE;
            fastio_rdata(6) <= global_interrupt_IE;
            fastio_rdata(7) <= global_interrupt;

        -- @IO:GS $FFDF00C - VFPGA SHA1 hash of architecture LSBs
        -- @IO:GS $FFDF00D - VFPGA SHA1 hash of architecture LSBs
        -- @IO:GS $FFDF00E - VFPGA SHA1 hash of architecture LSBs
        -- @IO:GS $FFDF00F - VFPGA SHA1 hash of architecture LSBs
          -- XXX PGS: 20190215: We only had 11 of the 32 bits in the 
          when x"0c" => fastio_rdata <= x"CA"; -- Architecture file SHA1 LSB 
          when x"0d" => fastio_rdata <= x"04"; -- Architecture file SHA1 LSB
          when x"0e" => fastio_rdata <= x"00"; -- Architecture file SHA1 LSB
          when x"0f" => fastio_rdata <= x"00"; -- Architecture file SHA1 LSB

          -- Now we allow setting/getting the logical clock divisor and #
          -- of logical cycles the vFPGA should run before
          -- triggering an interrupt
          when x"10" => fastio_rdata <= reg_clk_div(7 downto 0);
          when x"11" => fastio_rdata <= reg_clk_div(9 downto 8);
          when x"12" => fastio_rdata <= clk_cycle_counter_remainder(7 downto 0);
          when x"13" => fastio_rdata <= clk_cycle_counter_remainder(15 downto 8);
          when x"14" => fastio_rdata <= clk_cycle_counter_remainder(23 downto 16);

        -- @IO:GS $FFDF015 - VFPGA config access register: Reads or writes single byte of bitstream
          when x"15" =>
            -- Read a byte of the config
            case config_access_phase is
              when 0 => fastio_rdata <= vfpga_config_out(7 downto 0);
              when 1 => fastio_rdata <= vfpga_config_out(15 downto 8);
              when 2 => fastio_rdata <= vfpga_config_out(23 downto 16);
              when 3 => fastio_rdata <= vfpga_config_out(31 downto 24);
            end case;
            if config_access_phase = 3 then
              config_access_phase <= 0;
              -- Write the read word back to rotate it through and make the
              -- next visible.  this is safe to do only when the FPGA is paused,
              -- either normally, or because the machine is in hypervisor mode,
              -- which automatically pauses the FPGA.
              vFPGA_config_valid <= '1';
              vFPGA_config_in <= vFPGA_config_out;
            else
              config_access_phase <= config_access_phase + 1;
            end if;

        -- @IO:GS $FFDF015 - VFPGA config access register: Reads or writes single byte of state snapshot vector
          when x"16" =>
            -- Read a byte of the snapshot
            case snapshot_access_phase is
              when 0 => fastio_rdata <= vfpga_snap_out(7 downto 0);
              when 1 => fastio_rdata <= vfpga_snap_out(15 downto 8);
              when 2 => fastio_rdata <= vfpga_snap_out(23 downto 16);
              when 3 => fastio_rdata <= vfpga_snap_out(31 downto 24);
            end case;

            if snapshot_access_phase = 3 then
              snapshot_access_phase <= 0;
              -- Similar to the above, we rotate the state around
              vFPGA_snap_shift <= '1';
              vFPGA_snap_in <= vFPGA_snap_out;
            else
              snapshot_access_phase <= snapshot_access_phase + 1;
            end if;
            
          when others =>
            null;
        end case;
      end if;
    end if;
  end process;

  -- Snap save --
  -- This is super simple: The rising edge of the hypervisor mode transition
  -- can be used to pull the data out.
  vFPGA_snap_save <= hypervisor_mode;

  -- Snap restore --
  -- This is simply the opposite of the above
  vFPGA_snap_restore <= not hypervisor_mode;

  -- Write vclk divisor --
  process(pixel_clock)
  begin
    if rising_edge(clock) then
      if vFPGA_reset = '1' then
        reg_clk_div <= (others => '1');
        -- @IO:GS $FFDF010 - VFPGA logical clock divisor (LSB)
      elsif fastio_write='1' and cs_vfpga='1' and fastio_address(7 downto 0) = x"10" then
        reg_clk_div(7 downto 0) <= fastio_wdata;
        -- @IO:GS $FFDF011 - VFPGA logical clock divisor (MSB)
      elsif fastio_write='1' and cs_vfpga='1' and fastio_address(7 downto 0) = x"11" then
        reg_clk_div(9 downto 8) <= fastio_wdata(1 downto 0);
      end if;
    end if;
  end process;


  -- Write vclk cycle counter --
  process(pixel_clock)
  begin
    if rising_edge(pixel_clock) then
      old_write_clkcnt <= write_clkcnt;
      clk_cycle_counter_valid <= write_clkcnt and not(old_write_clkcnt);
      if vFPGA_reset = '1' then
        reg_clk_cycle_counter <= (others => '0');
        write_clkcnt <= '0';
        -- @IO:GS $FFDF012 - VFPGA cycle clock counter (LSB)
        -- @IO:GS $FFDF013 - VFPGA cycle clock counter (SSB)
        -- @IO:GS $FFDF014 - VFPGA cycle clock counter (MSB)
      elsif fastio_write='1' and cs_vfpga='1' and fastio_address(7 downto 0) = x"12" then
        reg_clk_cycle_couonter(7 downto 0) <= fastio_wdata(7 downto 0);
        write_clkcnt <= '1';
      elsif fastio_write='1' and cs_vfpga='1' and fastio_address(7 downto 0) = x"13" then
        reg_clk_cycle_couonter(15 downto 8) <= fastio_wdata(7 downto 0);
        write_clkcnt <= '1';
      elsif fastio_write='1' and cs_vfpga='1' and fastio_address(7 downto 0) = x"14" then
        reg_clk_cycle_couonter(23 downto 16) <= fastio_wdata(7 downto 0);
        write_clkcnt <= '1';
      else
        write_clkcnt <= '0';
      end if;
    end if;
  end process;

  vFPGA_inputs <= std_ulogic_vector(INPUTS);
  OUTPUTS <= std_logic_vector(vFPGA_outputs);

end Behavioral;