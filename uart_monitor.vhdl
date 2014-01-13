library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use Std.TextIO.all;

entity uart_monitor is
  port (
    reset : in std_logic;
    dotclock : in std_logic;
    tx : out std_logic;
    rx : in  std_logic;
    activity : out std_logic);
end uart_monitor;

architecture behavioural of uart_monitor is
  component UART_TX_CTRL is
    Port ( SEND : in  STD_LOGIC;
           DATA : in  STD_LOGIC_VECTOR (7 downto 0);
           CLK : in  STD_LOGIC;
           READY : out  STD_LOGIC;
           UART_TX : out  STD_LOGIC);
  end component;

  component uart_rx is
    Port ( clk : in  STD_LOGIC;
           UART_RX : in  STD_LOGIC;
           data : out  STD_LOGIC_VECTOR (7 downto 0);
           data_ready : out std_logic;
           data_acknowledge : in std_logic
           );
  end component;

-- raise for one cycle when we have a byte ready to send.
-- should only be asserted when tx_ready='1'.
  signal tx_trigger : std_logic := '0';
-- the byte to send.
  signal tx_data : std_logic_vector(7 downto 0);
-- indicates that uart is ready to TX the next byte.
  signal tx_ready : std_logic;

  signal rx_data : std_logic_vector(7 downto 0);
  signal rx_ready : std_logic;
  signal rx_acknowledge : std_logic := '0';

-- Counter for slow clock derivation (for testing at least)
  signal counter : unsigned(31 downto 0) := (others => '0');
  signal tx_counter : std_logic;

  signal blink : std_logic := '1';

-- Buffer to hold entered command
  signal cmdbuffer : String(1 to 256);
  signal cmdlen : integer := 0;

  constant bannerMessage : String := "\r\n\r\n--------------------------------\r\n65GS Serial Monitor\r\n---------------------------------\r\nType ? for help.\r\n";
  signal banner_position : integer := 1;
  constant helpMessage : String :=
    "?                       - Display this help\r\n" &
    "r                       - Print processor state.\r\n" &
    "s <address> <value>     - Set memory.\r\n" &
    "m <address>             - Display contents of memory\r\n";

  type monitor_state is (Reseting,PrintBanner,PrintPrompt,AcceptingInput);
  signal state : monitor_state := Reseting;

begin

  uart_tx0: uart_tx_ctrl
    port map (
      send    => tx_trigger,
      clk     => dotclock,
      data    => tx_data,
      ready   => tx_ready,
      uart_tx => tx);

  uart_rx0: uart_rx 
    Port map ( clk => dotclock,
               UART_RX => rx,
               data => rx_data,
               data_ready => rx_ready,
               data_acknowledge => rx_acknowledge);

  -- purpose: test uart output
  testclock: process (dotclock)
    -- purpose: Process a character typed by the user.
    procedure character_received (char : in character) is
    begin  -- character_received
      -- Echo character back to user
      tx_data <= std_logic_vector(to_unsigned(natural(character'pos(char)), 8));
      tx_trigger <= '1';
    end character_received;
    

  begin  -- process testclock
    if reset='1' then
      state <= Reseting;      
    elsif rising_edge(dotclock) then
      -- Update counter and clear outputs
      counter <= counter + 1;
      tx_counter <= std_logic(counter(27));
      rx_acknowledge <= '0';
      tx_trigger<='0';

      -- If there is a character waiting
      if rx_ready = '1' then
        blink <= not blink;
        activity <= blink;
        rx_acknowledge<='1';
        character_received(character'val(to_integer(unsigned(rx_data))));
      end if;

      -- General state machine
      case state is
        when Reseting =>
          banner_position <= 1;
          state <= PrintBanner;
        when PrintBanner =>
          if tx_ready='1' then
            tx_data <= std_logic_vector(to_unsigned(natural(character'pos(bannerMessage(banner_position))), 8));
            tx_trigger <= '1';
            if banner_position<bannerMessage'length then
              banner_position <= banner_position + 1;
            else
              state <= PrintPrompt;
            end if;
          end if;
        when PrintPrompt =>
          if tx_ready='1' then
            tx_data <= std_logic_vector(to_unsigned(natural(character'pos('.')), 8));
            tx_trigger <= '1';
            state <= AcceptingInput;
          end if;
        when others => null;
      end case;
    end if;
  end process testclock;
  
end behavioural;
