#/bin/bash

rm -f workers
killall -9 SumEulerWorker

ghc -O2 -i../src -XScopedTypeVariables SumEulerWorker
ghc -O2 -i../src -XScopedTypeVariables SumEulerMaster

./SumEulerWorker 1 127.0.0.1 8080 >> workers &
./SumEulerWorker 1 127.0.0.1 8081 >> workers &
./SumEulerWorker 1 127.0.0.1 8082 >> workers &
./SumEulerWorker 1 127.0.0.1 8083 >> workers &
./SumEulerWorker 1 127.0.0.1 8084 >> workers &
./SumEulerWorker 1 127.0.0.1 8085 >> workers &
./SumEulerWorker 1 127.0.0.1 8086 >> workers &
./SumEulerWorker 1 127.0.0.1 8087 >> workers &

echo "Waiting for all workers to be ready"
sleep 1
cat workers | xargs ./SumEulerMaster 127.0.0.1 8090 
