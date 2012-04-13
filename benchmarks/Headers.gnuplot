set title "Roundtrip (us)"
set yrange [0:150]
plot "JustPingHaskell.data" smooth bezier with lines title "JustPingHaskell (NOT -threaded)", \
     "JustPingHaskell2.data" smooth bezier with lines title "JustPingHaskell", \
     "JustPingWithHeader.data" smooth bezier with lines title "JustPingWithHeader", \
     "JustPingOneRecv.data" smooth bezier with lines title "JustPingOneRecv", \
     "JustPingCacheHeader.data" smooth bezier with lines title "JustPingCacheHeader", \
     "JustPingC.data" smooth bezier with lines title "JustPingC"
set terminal postscript color
set output "Headers.ps"
plot "JustPingHaskell.data" smooth bezier with lines title "JustPingHaskell (NOT -threaded)", \
     "JustPingHaskell2.data" smooth bezier with lines title "JustPingHaskell", \
     "JustPingWithHeader.data" smooth bezier with lines title "JustPingWithHeader", \
     "JustPingOneRecv.data" smooth bezier with lines title "JustPingOneRecv", \
     "JustPingCacheHeader.data" smooth bezier with lines title "JustPingCacheHeader", \
     "JustPingC.data" smooth bezier with lines title "JustPingC"
