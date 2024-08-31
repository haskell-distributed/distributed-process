set title "Roundtrip (us)"
set yrange [0:150]
plot "JustPingHaskell.data" smooth bezier with lines title "JustPingHaskell", \
     "JustPingTransport.data" smooth bezier with lines title "JustPingTransport"
set terminal postscript color
set output "NewTransport.ps"
plot "JustPingHaskell.data" smooth bezier with lines title "JustPingHaskell", \
     "JustPingTransport.data" smooth bezier with lines title "JustPingTransport"
