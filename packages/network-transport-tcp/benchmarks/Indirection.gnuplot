set title "Roundtrip (us)"
set yrange [0:150]
plot "JustPingWithHeader.data" smooth bezier with lines title "JustPingWithHeader", \
     "JustPingThroughChan.data" smooth bezier with lines title "JustPingThroughChan", \
     "JustPingThroughMVar.data" smooth bezier with lines title "JustPingThroughMVar", \
     "JustPingTwoSocketPairs.data" smooth bezier with lines title "JustPingTwoSocketPairs", \
     "JustPingTwoSocketPairsND.data" smooth bezier with lines title "JustPingTwoSocketPairs (--NoDelay)", \
     "JustPingTransport.data" smooth bezier with lines title "JustPingTransport"
set terminal postscript color
set output "Indirection.ps"
plot "JustPingWithHeader.data" smooth bezier with lines title "JustPingWithHeader", \
     "JustPingThroughChan.data" smooth bezier with lines title "JustPingThroughChan", \
     "JustPingThroughMVar.data" smooth bezier with lines title "JustPingThroughMVar", \
     "JustPingTwoSocketPairs.data" smooth bezier with lines title "JustPingTwoSocketPairs", \
     "JustPingTwoSocketPairsND.data" smooth bezier with lines title "JustPingTwoSocketPairs (--NoDelay)", \
     "JustPingTransport.data" smooth bezier with lines title "JustPingTransport"
