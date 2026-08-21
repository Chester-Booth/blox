import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    property string scriptRoot: ""
    property int notesSaveRevision: 0
    property bool notesSaveBusy: false
    property string notesSaveError: ""
    property bool generatedRefreshBusy: false
    property string generatedRefreshError: ""
    property bool performanceBusy: false
    property string performanceError: ""
    property string performanceProcessError: ""
    property bool performanceProcessExited: false
    property bool performanceStderrFinished: false
    property int performanceExitCode: 0
    property int performanceExitStatus: 0
    property string notesProcessError: ""
    property string generatedProcessError: ""

    signal controlRefreshRequested()
    signal performanceRefreshRequested()
    signal todoRefreshRequested()

    function errorMessage(prefix, exitCode, errorOutput) {
        const lines = errorOutput.trim().split("\n").filter((line) => {
            return line.trim().length > 0;
        });
        const detail = lines.length > 0 ? lines[lines.length - 1].trim().slice(0, 180) : "";
        return detail.length > 0 ? prefix + ": " + detail : prefix + " (exit " + exitCode + ")";
    }

    function run(command) {
        if (command.length === 0)
            return ;

        Quickshell.execDetached(["sh", "-c", command]);
        refreshDelay.restart();
    }

    function runArgs(args) {
        if (args.length === 0)
            return ;

        Quickshell.execDetached(args);
        refreshDelay.restart();
    }

    function runPerformance(command) {
        if (command.length === 0 || performanceProcess.running)
            return ;

        performanceProcessError = "";
        performanceProcessExited = false;
        performanceStderrFinished = false;
        performanceError = "";
        performanceBusy = true;
        performanceProcess.command = ["timeout", "45s", "sh", "-c", command];
        performanceProcess.running = true;
    }

    function finishPerformance() {
        if (!performanceProcessExited || !performanceStderrFinished)
            return ;

        performanceBusy = false;
        if (performanceExitCode !== 0 || performanceExitStatus !== 0)
            performanceError = errorMessage("Performance action failed", performanceExitCode, performanceProcessError);

        controlRefreshRequested();
        performanceRefreshRequested();
    }

    function saveNotes(file, body) {
        if (notesProcess.running) {
            notesSaveError = "A note is already being saved.";
            return ;
        }
        if (file.length === 0) {
            notesSaveError = "No note file is selected.";
            return ;
        }
        notesProcessError = "";
        notesSaveError = "";
        notesSaveBusy = true;
        notesProcess.command = [scriptRoot + "/todo/save.py", file, body];
        notesProcess.running = true;
    }

    function refreshGeneratedNotes() {
        if (generatedProcess.running) {
            generatedRefreshError = "Generated notes are already being refreshed.";
            return ;
        }
        generatedProcessError = "";
        generatedRefreshError = "";
        generatedRefreshBusy = true;
        generatedProcess.command = ["timeout", "90s", scriptRoot + "/todo/generated-refresh.sh"];
        generatedProcess.running = true;
    }

    Timer {
        id: refreshDelay

        interval: 500
        repeat: false
        onTriggered: {
            root.controlRefreshRequested();
            root.performanceRefreshRequested();
        }
    }

    Process {
        id: performanceProcess

        onExited: (exitCode, exitStatus) => {
            root.performanceExitCode = exitCode;
            root.performanceExitStatus = exitStatus;
            root.performanceProcessExited = true;
            root.finishPerformance();
        }

        stderr: StdioCollector {
            onStreamFinished: {
                root.performanceProcessError = this.text;
                root.performanceStderrFinished = true;
                root.finishPerformance();
            }
        }

    }

    Process {
        id: notesProcess

        onExited: (exitCode, exitStatus) => {
            root.notesSaveBusy = false;
            if (exitCode === 0 && exitStatus === 0) {
                root.notesSaveRevision += 1;
                root.notesSaveError = "";
            } else {
                root.notesSaveError = root.errorMessage("Could not save the note", exitCode, root.notesProcessError);
            }
            root.todoRefreshRequested();
        }

        stderr: StdioCollector {
            onStreamFinished: root.notesProcessError = this.text
        }

    }

    Process {
        id: generatedProcess

        onExited: (exitCode, exitStatus) => {
            root.generatedRefreshBusy = false;
            if (exitCode === 0 && exitStatus === 0)
                root.generatedRefreshError = "";
            else if (exitCode === 75)
                root.generatedRefreshError = "Generated notes are already being refreshed.";
            else
                root.generatedRefreshError = root.errorMessage("Could not refresh generated notes", exitCode, root.generatedProcessError);
            root.todoRefreshRequested();
        }

        stderr: StdioCollector {
            onStreamFinished: root.generatedProcessError = this.text
        }

    }

}
