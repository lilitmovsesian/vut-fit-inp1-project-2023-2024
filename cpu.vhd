-- cpu.vhd: Simple 8-bit CPU (BrainFuck interpreter)
-- Copyright (C) 2023 Brno University of Technology,
--                    Faculty of Information Technology
-- Author(s): Lili Movsesian <xmovse00>
--
LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.std_logic_arith.ALL;
USE ieee.std_logic_unsigned.ALL;

-- ----------------------------------------------------------------------------
--                        Entity declaration
-- ----------------------------------------------------------------------------
ENTITY cpu IS
    PORT (
        CLK : IN STD_LOGIC; -- hodinovy signal
        RESET : IN STD_LOGIC; -- asynchronni reset procesoru
        EN : IN STD_LOGIC; -- povoleni cinnosti procesoru

        -- synchronni pamet RAM
        DATA_ADDR : OUT STD_LOGIC_VECTOR(12 DOWNTO 0); -- adresa do pameti
        DATA_WDATA : OUT STD_LOGIC_VECTOR(7 DOWNTO 0); -- mem[DATA_ADDR] <- DATA_WDATA pokud DATA_EN='1'
        DATA_RDATA : IN STD_LOGIC_VECTOR(7 DOWNTO 0); -- DATA_RDATA <- ram[DATA_ADDR] pokud DATA_EN='1'
        DATA_RDWR : OUT STD_LOGIC; -- cteni (0) / zapis (1)
        DATA_EN : OUT STD_LOGIC; -- povoleni cinnosti

        -- vstupni port
        IN_DATA : IN STD_LOGIC_VECTOR(7 DOWNTO 0); -- IN_DATA <- stav klavesnice pokud IN_VLD='1' a IN_REQ='1'
        IN_VLD : IN STD_LOGIC; -- data platna
        IN_REQ : OUT STD_LOGIC; -- pozadavek na vstup data

        -- vystupni port
        OUT_DATA : OUT STD_LOGIC_VECTOR(7 DOWNTO 0); -- zapisovana data
        OUT_BUSY : IN STD_LOGIC; -- LCD je zaneprazdnen (1), nelze zapisovat
        OUT_WE : OUT STD_LOGIC; -- LCD <- OUT_DATA pokud OUT_WE='1' a OUT_BUSY='0'

        -- stavove signaly
        READY : OUT STD_LOGIC; -- hodnota 1 znamena, ze byl procesor inicializovan a zacina vykonavat program
        DONE : OUT STD_LOGIC -- hodnota 1 znamena, ze procesor ukoncil vykonavani programu (narazil na instrukci halt)
    );
END cpu;
-- ----------------------------------------------------------------------------
--                      Architecture declaration
-- ----------------------------------------------------------------------------
architecture behavioral of cpu is

    -- pri tvorbe kodu reflektujte rady ze cviceni INP, zejmena mejte na pameti, ze 
    --   - nelze z vice procesu ovladat stejny signal,
    --   - je vhodne mit jeden proces pro popis jedne hardwarove komponenty, protoze pak
    --      - u synchronnich komponent obsahuje sensitivity list pouze CLK a RESET a 
    --      - u kombinacnich komponent obsahuje sensitivity list vsechny ctene signaly. 
   
    --pc signals
    signal pc_reg  :  std_logic_vector(12 downto 0); 
    signal pc_inc  :  std_logic;
    signal pc_dec  :  std_logic;
   
    --ptr signals
    signal ptr_reg  :  std_logic_vector(12 downto 0);
    signal ptr_inc  :  std_logic;
    signal ptr_dec  :  std_logic;
   
    --cnt signals
    signal cnt_reg  :  std_logic_vector(12 downto 0);
    signal cnt_inc  :  std_logic;
    signal cnt_dec  :  std_logic;
   
    --Definition of automat states
    type fsm_state is (
        state_reset,
        state_enable_init,
        state_init,
        state_ready,
        state_fetch,
        state_decode,
        state_ptr_inc,
        state_ptr_dec,
        state_value_inc_start,
        state_value_inc_mid,
        state_value_inc_end,
        state_value_dec_start,
        state_value_dec_mid,
        state_value_dec_end,
        state_while_start_1,
        state_while_start_2,
        state_while_start_3,
        state_while_start_4,
        state_while_start_5,
        state_while_end_1,
        state_while_end_2,
        state_while_end_3,
        state_while_end_4,
        state_while_end_5,
        state_while_end_6,
        state_break_1,
        state_break_2,
        state_break_3,
        state_break_4,
        state_write_start,
        state_write_end,
        state_read_start,
        state_read_mid,
        state_read_end,
        state_halt,
        state_ignore
    );

    signal state  :  fsm_state;
    signal next_state  :  fsm_state;
    signal mux1_select  :  std_logic;
    signal mux2_select  :  std_logic_vector(1 downto 0);
   
    --pc register process
    begin
      pc_counter: process (RESET, CLK, pc_reg, pc_inc, pc_dec)
      begin
         if RESET = '1' then
            pc_reg <= "0000000000000";
         elsif (CLK'event) and (CLK = '1') then
           if pc_dec = '1' then
              pc_reg <= pc_reg - 1;
            elsif pc_inc = '1' then
               pc_reg <= pc_reg + 1;  
           end if;
         end if;
      end process;

    --ptr register process, ptr_reg is a circular buffer 
    ptr_counter: process (RESET, CLK, ptr_reg, ptr_inc, ptr_dec)
    begin
      if RESET = '1' then
         ptr_reg <= "0000000000000";
      elsif (CLK'event) and (CLK = '1') then
         if ptr_inc = '1' then
            if ptr_reg = "1111111111111" then
               ptr_reg <= "0000000000000";
            else
               ptr_reg <= ptr_reg + 1;
            end if;
         elsif ptr_dec = '1' then
            if ptr_reg = "0000000000000" then
               ptr_reg <= "1111111111111";
            else
               ptr_reg <= ptr_reg - 1;
            end if;
         end if;
      end if;
   end process;

   --cnt register process
   cnt_counter: process (RESET, CLK, cnt_reg, cnt_inc, cnt_dec)
   begin
      if RESET = '1' then
         cnt_reg <= "0000000000000";
      elsif (CLK'event) and (CLK = '1') then
         if cnt_dec = '1' then
            cnt_reg <= cnt_reg - 1;
         elsif cnt_inc = '1' then
            cnt_reg <= cnt_reg + 1;
         end if;
      end if;
   end process;

   --mux1 process, pc_reg points to program data, ptr_reg points to data 
   mux1: process(pc_reg, ptr_reg, mux1_select) 
   begin   
        if mux1_select = '0' then
            DATA_ADDR <= pc_reg;
         elsif mux1_select = '1' then
            DATA_ADDR <= ptr_reg;
         else 
            DATA_ADDR <= "0000000000000";
         end if;
   end process;

   --mux2 process
   mux2: process (RESET, CLK, mux2_select)
   begin
      if (CLK'event) and (CLK = '1') then
         if mux2_select = "00" then
            DATA_WDATA <= IN_DATA;
         elsif mux2_select = "01" then
            DATA_WDATA <= DATA_RDATA + 1;
         elsif mux2_select = "10" then
            DATA_WDATA <= DATA_RDATA - 1;
        else
         end if;
      end if;
   end process;

   
   state_logic: process (CLK, RESET, EN) is 
   begin
      if RESET = '1' then
         state <= state_reset;
      elsif (CLK'event) and (CLK = '1') then 
         if EN = '1' then 
            state <= next_state;
         end if;
      end if;
   end process;

    fsm : process (state, OUT_BUSY, IN_VLD, DATA_RDATA, cnt_reg, ptr_reg, pc_reg) IS
    begin
        pc_inc <= '0';
        pc_dec <= '0';
        ptr_inc <= '0';
        ptr_dec <= '0';
        cnt_inc <= '0';
        cnt_dec <= '0';
        DATA_EN <= '0';
        IN_REQ <= '0';
        OUT_WE <= '0';
        DATA_RDWR <= '0';
        OUT_DATA <= DATA_RDATA;
        mux2_select <= "00";

        case state is
            --resets ready and done
            when state_reset =>
                READY <= '0';
                DONE <= '0';
                next_state <= state_enable_init;
            when state_enable_init =>
                mux1_select <= '1';
                DATA_EN <= '1';
                DATA_RDWR <= '0';
                next_state <= state_init;
            --if @ is encountered, state ready, else loops in 2 states
            when state_init =>
                if DATA_RDATA = X"40" then
                    ptr_inc <= '1';
                    next_state <= state_ready;
                else
                    ptr_inc <= '1';
                    next_state <= state_enable_init;
                end if;
            --sets ready
            when state_ready =>
                READY <= '1';
                next_state <= state_fetch;
            when state_fetch =>
                mux1_select <= '0';
                DATA_RDWR <= '0';
                DATA_EN <= '1';
                next_state <= state_decode;
            --reads the symbols on RDATA and chooses a state
            when state_decode =>
                case DATA_RDATA is
                    when X"3E" =>
                        next_state <= state_ptr_inc;
                    when X"3C" =>
                        next_state <= state_ptr_dec;
                    when X"2B" =>
                        next_state <= state_value_inc_start;
                    when X"2D" =>
                        next_state <= state_value_dec_start;
                    when X"5B" =>
                        next_state <= state_while_start_1;
                    when X"5D" =>
                        next_state <= state_while_end_1;
                    when X"7E" =>
                        next_state <= state_break_1;
                    when X"2E" =>
                        next_state <= state_write_start;
                    when X"2C" =>
                        next_state <= state_read_start;
                    when X"40" =>
                        next_state <= state_halt;
                    when others =>
                        next_state <= state_ignore;
                end case;
            --ptr incrementation
            when state_ptr_inc =>
                ptr_inc <= '1';
                pc_inc <= '1';
                next_state <= state_fetch;
            --ptr decrementation
            when state_ptr_dec =>
                ptr_dec <= '1';
                pc_inc <= '1';
                next_state <= state_fetch;
            --value is increased with help of mux2
            --read position of RDWR is set
            when state_value_inc_start =>
                mux1_select <= '1';
                DATA_EN <= '1';
                DATA_RDWR <= '0';
                next_state <= state_value_inc_mid;
            when state_value_inc_mid =>
                mux2_select <= "01";
                next_state <= state_value_inc_end;
            --write position of RDWR is set, program data pointer is increased
            when state_value_inc_end =>
                DATA_EN <= '1';
                DATA_RDWR <= '1';
                pc_inc <= '1';
                next_state <= state_fetch;
            --value decrementation
            when state_value_dec_start =>
                mux1_select <= '1';
                DATA_EN <= '1';
                DATA_RDWR <= '0';
                next_state <= state_value_dec_mid;
            when state_value_dec_mid =>
                mux2_select <= "10";
                next_state <= state_value_dec_end;
            when state_value_dec_end =>
                DATA_EN <= '1';
                DATA_RDWR <= '1';
                pc_inc <= '1';
                next_state <= state_fetch;
            --if the peripheral is not busy with the previous instruction,
            --enables the writing and writes the data to OUT_DATA
            when state_write_start =>
                mux1_select <= '1';
                DATA_EN <= '1';
                DATA_RDWR <= '0';
                next_state <= state_write_end;
            when state_write_end =>
                if OUT_BUSY = '1' then
                    next_state <= state_write_start;
                else
                    OUT_WE <= '1';
                    OUT_DATA <= DATA_RDATA;
                    pc_inc <= '1';
                    next_state <= state_fetch;
                end if;  
            --if input valid signal is set, the data from IN_DATA is read, else looped
            when state_read_start =>
                mux1_select <= '1';
                IN_REQ <= '1';
                DATA_EN <= '1';
                DATA_RDWR <= '0';
                next_state <= state_read_mid;
            when state_read_mid =>  
                if IN_VLD = '0' then
                    next_state <= state_read_start;
                    IN_REQ <= '1';
                else
                    DATA_EN <= '1';
                    DATA_RDWR <= '1';
                    IN_REQ <= '1';
                    mux2_select <= "00";
                    pc_inc <= '1';
                   next_state <= state_read_end;
                end if;
            when state_read_end =>
                DATA_RDWR <= '0';
                next_state <= state_fetch;
            --while loop start
            when state_while_start_1 =>
                DATA_EN <= '1';
                pc_inc <= '1';
                mux1_select <= '1';
                next_state <= state_while_start_2;      
            when state_while_start_2 =>
                if DATA_RDATA = "00000000" then
                    cnt_inc <= '1';
                    next_state <= state_while_start_3;
                else
                    next_state <= state_fetch;
                end if;
            --checks if all while loops are finished
            when state_while_start_3 =>
                if cnt_reg = "0000000000000" then
                    next_state <= state_fetch;
                else 
                    next_state <=state_while_start_4;
                end if;
            when state_while_start_4 =>
                    DATA_EN <= '1';
                    mux1_select <= '0';
                    next_state <= state_while_start_5;
            --decrements or increments the cnt_reg based on the [ and ] symbols on DATA_RDATA
            when state_while_start_5 =>
                if DATA_RDATA = X"5D" then
                    cnt_dec <= '1';
                    pc_inc <= '1';
                    next_state <= state_while_start_3;
                elsif DATA_RDATA = X"5B" then
                    cnt_inc <= '1';
                    pc_inc <= '1';
                    next_state <= state_while_start_3;
                end if ;
            when state_while_end_1 => 
                DATA_EN <= '1';
                mux1_select <= '1';
                next_state <= state_while_end_2;
            when state_while_end_2 =>
                if DATA_RDATA = "00000000" then
                    pc_inc <= '1';
                    next_state <= state_fetch;
                else
                    cnt_inc <= '1';
                    pc_dec <= '1';
                    next_state <= state_while_end_3;
                end if;
            --checks if all loops are ended
            when state_while_end_3 =>
                if cnt_reg = "0000000000000" then
                    next_state <= state_fetch;
                else
                    next_state <= state_while_end_4;
                end if;
            when state_while_end_4 =>
                DATA_EN <= '1';
                mux1_select <= '0';
                next_state <= state_while_end_5; 
            --decrements or increments the cnt_reg based on the [ and ] symbols on DATA_RDATA
            when state_while_end_5 =>
                if DATA_RDATA = X"5B" then
                    cnt_dec <= '1';
                elsif DATA_RDATA = X"5D" then
                    cnt_inc <= '1';
                end if;           
                next_state <= state_while_end_6;
            when state_while_end_6 =>
                if cnt_reg = "0000000000000" then
                    pc_inc <= '1';
                else
                    pc_dec <= '1';
                end if;
                next_state <= state_while_end_3;
            --break instruction 
            when state_break_1 =>
                    pc_inc <= '1';
                    cnt_inc <= '1';
                    next_state <= state_break_2;
            when state_break_2 =>
                if cnt_reg = "0000000000000" then
                    next_state <= state_fetch; 
                else
                    next_state <= state_break_3;
                end if;
            when state_break_3 =>
                DATA_EN <= '1';

                mux1_select <= '0';
                next_state <= state_break_4;
            --decrements or increments the cnt_reg based on the [ and ] symbols on DATA_RDATA
            when state_break_4 =>
                if DATA_RDATA = X"5D" then
                    cnt_dec <= '1';
                elsif DATA_RDATA = X"5B" then
                    cnt_inc <= '1';
                end if;
                pc_inc <= '1';
                next_state <= state_break_2;
            --program is complete
            when state_halt =>
                DONE <= '1';
                next_state <=state_halt;
            when state_ignore =>
                pc_inc <= '1';
                next_state <= state_fetch;
        end case;
    end process;
end behavioral;