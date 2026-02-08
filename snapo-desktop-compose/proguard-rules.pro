-dontwarn androidx.compose.material.**

# Mordant bundles optional terminal backends for Graal Native Image and newer
# Java FFM APIs. They are not used in our JVM desktop runtime on JDK 17.
-dontwarn com.github.ajalt.mordant.terminal.terminalinterface.nativeimage.**
-dontwarn com.github.ajalt.mordant.terminal.terminalinterface.ffm.**
-dontwarn org.graalvm.**
-dontwarn com.oracle.svm.core.annotate.**
-dontwarn java.lang.foreign.**
-dontwarn java.lang.invoke.MethodHandles
-dontwarn java.lang.invoke.VarHandle

# Keep Clikt unshrunk/unoptimized in release artifacts. This avoids brittle
# optimizer interactions in generated parser/help code paths.
-keep,includedescriptorclasses class com.github.ajalt.clikt.** { *; }

# Mordant terminal providers are loaded via ServiceLoader, so keep JNA backend
# provider implementation classes from Mordant.
-keep class com.github.ajalt.mordant.terminal.terminalinterface.jna.** { *; }
