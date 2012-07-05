#!/bin/bash
TestLocalBackend=dist/build/TestLocalBackend/TestLocalBackend
$TestLocalBackend client 127.0.0.1 8080 & 
$TestLocalBackend client 127.0.0.1 8081 & 
$TestLocalBackend client 127.0.0.1 8082 & 
$TestLocalBackend client 127.0.0.1 8083 & 
sleep 2 # give clients a change to start
$TestLocalBackend server 127.0.0.1 8084
