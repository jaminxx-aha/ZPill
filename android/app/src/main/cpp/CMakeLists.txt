cmake_minimum_required(VERSION 3.22.1)
project(usbreset C)

add_library(usbreset SHARED usb_reset.c)
