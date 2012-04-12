set title "Roundtrip (us)"
set yrange [0:200]
plot "JustPingHaskell.data" smooth bezier with lines title "JustPingHaskell (NOT -threaded)", \
     "JustPingHaskell2.data" smooth bezier with lines title "JustPingHaskell", \
     "JustPingForkClient.data" smooth bezier with lines title "JustPingForkClient", \
     "JustPingNaiveHeader.data" smooth bezier with lines title "JustPingNaiveHeader", \
     "JustPingOneRecv.data" smooth bezier with lines title "JustPingOneRecv", \
     "JustPingCacheHeader.data" smooth bezier with lines title "JustPingCacheHeader", \
     "JustPingC.data" smooth bezier with lines title "JustPingC"
set terminal postscript color
set output "JustPing.ps"
plot "JustPingHaskell.data" smooth bezier with lines title "JustPingHaskell (NOT -threaded)", \
     "JustPingHaskell2.data" smooth bezier with lines title "JustPingHaskell", \
     "JustPingForkClient.data" smooth bezier with lines title "JustPingForkClient", \
     "JustPingNaiveHeader.data" smooth bezier with lines title "JustPingNaiveHeader", \
     "JustPingOneRecv.data" smooth bezier with lines title "JustPingOneRecv", \
     "JustPingCacheHeader.data" smooth bezier with lines title "JustPingCacheHeader", \
     "JustPingC.data" smooth bezier with lines title "JustPingC"
