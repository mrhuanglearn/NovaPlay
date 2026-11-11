# libuzv_mpv.so calls MpvNative.onMpvRenderUpdate() by name (GetStaticMethodID) and its JNI symbols embed the class
# name, but no Kotlin code references the callback, so R8 would strip it in release builds: black video, audio only.
-keep class com.example.uzv.native_player.kernel.mpv.MpvNative { *; }

# Same for libuzv_mdk.so: its JNI_OnLoad looks up MdkNative.onMdkEvent by name and fails with JNI_ERR when R8 has
# stripped it, so the release build showed "MDK 内核不可用" and kept playing with MPV (seen on the phone, 2026-11-10).
-keep class com.example.uzv.native_player.kernel.mdk.MdkNative { *; }
