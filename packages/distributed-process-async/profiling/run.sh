#!/bin/sh
PROG=dtp
VIEW=open
FLAGS=
DIST_DIR=./dist


cabal build
mkdir -p ${DIST_DIR}/profiling
(
	cd ${DIST_DIR}/profiling
	../build/${PROG}/${PROG} ${FLAGS} +RTS -p -hc -s${PROG}.summary
	hp2ps ${PROG}.hp
)
${VIEW} ${DIST_DIR}/profiling/${PROG}.ps
cat ${DIST_DIR}/profiling/${PROG}.summary