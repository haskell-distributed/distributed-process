set title "Roundtrip (us)"
set yrange [0:200]
plot "JustPingHaskell.data" smooth bezier with lines title "JustPingHaskell", \
     "JustPingHaskell2.data" smooth bezier with lines title "JustPingHaskell (-threaded)", \
     "JustPingNaiveHeader.data" smooth bezier with lines title "JustPingNaiveHeader", \
     "JustPingC.data" smooth bezier with lines title "JustPingC"
set terminal postscript color
set output "JustPing.ps"
plot "JustPingHaskell.data" smooth bezier with lines title "JustPingHaskell", \
     "JustPingHaskell2.data" smooth bezier with lines title "JustPingHaskell (-threaded)", \
     "JustPingNaiveHeader.data" smooth bezier with lines title "JustPingNaiveHeader", \
     "JustPingC.data" smooth bezier with lines title "JustPingC"
