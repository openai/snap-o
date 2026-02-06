package com.openai.snapo.desktop.inspector.export

import java.awt.BorderLayout
import java.awt.Dialog
import java.io.File
import java.util.concurrent.atomic.AtomicReference
import java.util.prefs.Preferences
import javax.swing.JDialog
import javax.swing.JFileChooser
import javax.swing.JPanel
import javax.swing.SwingUtilities
import javax.swing.WindowConstants
import javax.swing.filechooser.FileNameExtensionFilter

private const val HarExportPrefsNode = "com.openai.snapo.desktop.inspector.export"
private const val HarExportLastDirectoryKey = "harExportLastDirectory"

internal data class NetworkInspectorHarExportDestination(
    val outputFile: File,
)

internal object NetworkInspectorHarExportDialog {
    private val prefs: Preferences by lazy {
        Preferences.userRoot().node(HarExportPrefsNode)
    }

    fun choose(defaultFileName: String): NetworkInspectorHarExportDestination? {
        val result = AtomicReference<NetworkInspectorHarExportDestination?>()
        runOnEdtAndWait {
            val initialFile = initialExportFile(defaultFileName)
            val chooser = JFileChooser().apply {
                dialogType = JFileChooser.SAVE_DIALOG
                approveButtonText = "Save"
                selectedFile = initialFile
                initialFile.parentFile?.let { parent ->
                    if (parent.exists() && parent.isDirectory) currentDirectory = parent
                }
                fileFilter = FileNameExtensionFilter("HTTP Archive (*.har)", "har")
            }

            val dialog = JDialog(null as Dialog?, "Export (sanitized)", true)
            dialog.defaultCloseOperation = WindowConstants.DISPOSE_ON_CLOSE
            dialog.contentPane = JPanel(BorderLayout()).apply {
                add(chooser, BorderLayout.CENTER)
            }

            chooser.addActionListener { event ->
                when (event.actionCommand) {
                    JFileChooser.APPROVE_SELECTION -> {
                        val selected = chooser.selectedFile ?: return@addActionListener
                        val outputFile = ensureHarExtension(selected)
                        rememberExportDirectory(outputFile)
                        result.set(
                            NetworkInspectorHarExportDestination(
                                outputFile = outputFile,
                            )
                        )
                        dialog.dispose()
                    }

                    JFileChooser.CANCEL_SELECTION -> dialog.dispose()
                }
            }

            dialog.pack()
            dialog.setLocationRelativeTo(null)
            dialog.isVisible = true
        }
        return result.get()
    }

    private inline fun runOnEdtAndWait(crossinline block: () -> Unit) {
        if (SwingUtilities.isEventDispatchThread()) {
            block()
            return
        }
        SwingUtilities.invokeAndWait { block() }
    }

    private fun initialExportFile(defaultFileName: String): File {
        val lastDirectory = loadLastExportDirectory() ?: return File(defaultFileName)
        return File(lastDirectory, defaultFileName)
    }

    private fun loadLastExportDirectory(): File? {
        val path = runCatching { prefs.get(HarExportLastDirectoryKey, null) }.getOrNull()
            ?: return null
        if (path.isBlank()) return null
        val directory = File(path)
        return directory.takeIf { it.exists() && it.isDirectory }
    }

    private fun rememberExportDirectory(outputFile: File) {
        val parent = outputFile.parentFile ?: return
        if (!parent.exists() || !parent.isDirectory) return
        runCatching { prefs.put(HarExportLastDirectoryKey, parent.absolutePath) }
    }

    private fun ensureHarExtension(file: File): File {
        if (file.name.lowercase().endsWith(".har")) return file
        return File(file.parentFile, "${file.name}.har")
    }
}
