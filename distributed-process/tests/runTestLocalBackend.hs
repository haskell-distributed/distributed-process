#!/bin/bash
TestLocalBackend=dist/build/TestLocalBackend/TestLocalBackend
$TestLocalBackend slave 127.0.0.1 8080 & 
sleep 1
$TestLocalBackend slave 127.0.0.1 8081 & 
sleep 1
$TestLocalBackend slave 127.0.0.1 8082 & 
sleep 1
$TestLocalBackend slave 127.0.0.1 8083 & 
sleep 1
$TestLocalBackend master 127.0.0.1 8084
