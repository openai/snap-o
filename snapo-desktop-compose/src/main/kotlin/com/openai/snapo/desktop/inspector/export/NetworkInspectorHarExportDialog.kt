package com.openai.snapo.desktop.inspector.export

import java.awt.BorderLayout
import java.awt.Dialog
import java.io.File
import java.util.concurrent.atomic.AtomicReference
import javax.swing.JDialog
import javax.swing.JFileChooser
import javax.swing.JPanel
import javax.swing.SwingUtilities
import javax.swing.WindowConstants
import javax.swing.filechooser.FileNameExtensionFilter

internal data class NetworkInspectorHarExportDestination(
    val outputFile: File,
)

internal object NetworkInspectorHarExportDialog {
    fun choose(defaultFileName: String): NetworkInspectorHarExportDestination? {
        val result = AtomicReference<NetworkInspectorHarExportDestination?>()
        runOnEdtAndWait {
            val chooser = JFileChooser().apply {
                dialogType = JFileChooser.SAVE_DIALOG
                approveButtonText = "Save"
                selectedFile = File(defaultFileName)
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
                        result.set(
                            NetworkInspectorHarExportDestination(
                                outputFile = ensureHarExtension(selected),
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

    private fun ensureHarExtension(file: File): File {
        if (file.name.lowercase().endsWith(".har")) return file
        return File(file.parentFile, "${file.name}.har")
    }
}
