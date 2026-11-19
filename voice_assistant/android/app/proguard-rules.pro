# Flutter rules
-keep class io.flutter.** { *; }

# Vosk Offline Engine
-keep class org.vosk.** { *; }
-dontwarn org.vosk.**

# Java Native Access (JNA)
-keep class com.sun.jna.** { *; }
-dontwarn com.sun.jna.**
-keepclassmembers class * extends com.sun.jna.* { *; }

# Keep Android Context and Framework Classes
-keep class android.content.Context { *; }
-keep class * extends android.content.Context

# Keep Baseflow permissions & Flutter plugins
-keep class com.baseflow.** { *; }
-keep class com.boskokg.flutter_blue_plus.** { *; }
