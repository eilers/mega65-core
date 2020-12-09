#!/bin/csh -f

if ( x"$1" == "x" ) then
  echo "usage: $0 <MCS file>"
  exit 0
endif

echo sed -e 's,THEMCSFILE,'"$1"',g' 
sed -e 's,THEMCSFILE,'"$1"',g' < nexys4ddr-write-flash.tcl > temp.tcl
/opt/Xilinx/Vivado/2019.2/bin/vivado -mode batch -nojournal -nolog -notrace -source temp.tcl
