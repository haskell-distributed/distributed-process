set title "Roundtrip (us)"
set yrange [0:300]
plot "JustPingHaskell.data" every 400::200 title "JustPingHaskell", \
     "JustPingHaskell2.data" every 400::100 title "JustPingHaskell (-threaded)", \
     "JustPingC.data" every 400::0 title "JustPingC"
set terminal postscript color
set output "JustPing.ps"
plot "JustPingHaskell.data" every 400::200 title "JustPingHaskell", \
     "JustPingHaskell2.data" every 400::100 title "JustPingHaskell (-threaded)", \
     "JustPingC.data" every 400::0 title "JustPingC"
