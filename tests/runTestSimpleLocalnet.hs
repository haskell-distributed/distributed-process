#!/bin/bash
TestSimpleLocalnet=dist/build/TestSimpleLocalnet/TestSimpleLocalnet
$TestSimpleLocalnet slave 127.0.0.1 8080 &
sleep 1
$TestSimpleLocalnet slave 127.0.0.1 8081 &
sleep 1
$TestSimpleLocalnet slave 127.0.0.1 8082 &
sleep 1
$TestSimpleLocalnet slave 127.0.0.1 8083 &
sleep 1
$TestSimpleLocalnet master 127.0.0.1 8084
