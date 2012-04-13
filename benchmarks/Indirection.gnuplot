set title "Roundtrip (us)"
set yrange [0:150]
plot "JustPingWithHeader.data" smooth bezier with lines title "JustPingWithHeader", \
     "JustPingThroughChan.data" smooth bezier with lines title "JustPingThroughChan", \
     "JustPingThroughMVar.data" smooth bezier with lines title "JustPingThroughMVar"
set terminal postscript color
set output "Headers.ps"
plot "JustPingWithHeader.data" smooth bezier with lines title "JustPingWithHeader", \
     "JustPingThroughChan.data" smooth bezier with lines title "JustPingThroughChan", \
     "JustPingThroughMVar.data" smooth bezier with lines title "JustPingThroughMVar"
