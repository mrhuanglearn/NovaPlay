cmake_minimum_required(VERSION 3.22.1)
project(uzv_mpv C)

# libmpv.so itself is NOT linked: the glue dlopen()s it so a device without it falls back to Exo (see uzv_mpv.c).
# Only libc / libdl are needed (the original libuzn_mpv.so links just those); liblog is added so mpv warnings reach logcat.
add_library(uzv_mpv SHARED uzv_mpv.c)
set_target_properties(uzv_mpv PROPERTIES C_STANDARD 99 C_STANDARD_REQUIRED ON)
target_compile_options(uzv_mpv PRIVATE -Wall -Wextra -fvisibility=hidden)
target_link_libraries(uzv_mpv dl log)

# JNI entry into the embedded Node.js runtime; libnode.so is dlopen()ed here too (see uzv_node.c).
add_library(uzv_node SHARED uzv_node.c)
set_target_properties(uzv_node PROPERTIES C_STANDARD 99 C_STANDARD_REQUIRED ON)
target_compile_options(uzv_node PRIVATE -Wall -Wextra -fvisibility=hidden)
target_link_libraries(uzv_node dl log)

# JNI glue for MDK (播放内核 → MDK); libmdk.so is dlopen()ed so builds without it fall back to Exo (see uzv_mdk.c).
add_library(uzv_mdk SHARED uzv_mdk.c)
set_target_properties(uzv_mdk PROPERTIES C_STANDARD 99 C_STANDARD_REQUIRED ON)
target_compile_options(uzv_mdk PRIVATE -Wall -Wextra -fvisibility=hidden)
target_link_libraries(uzv_mdk dl log android)
