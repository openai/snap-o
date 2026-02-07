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
