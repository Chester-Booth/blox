import qs.shared
import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    property string scriptRoot: ""
    property var notesSaveResult: actionResult(true, "ok", "", {pending: false})
    property var generatedRefreshResult: actionResult(true, "ok", "", {pending: false})
    property var performanceResult: actionResult(true, "ok", "", {pending: false})
    property var caffeineResult: actionResult(true, "ok", "", {pending: false})
    property var powerResult: actionResult(true, "ok", "", {pending: false})
    property int caffeineRevision: 0
    property bool caffeineBusy: false
    property string caffeineRaw: ""
    property bool caffeineExited: false
    property bool caffeineOutputFinished: false
    property int caffeineExitCode: 0
    property int caffeineExitStatus: 0
    property int notesSaveRevision: 0
    property bool notesSaveBusy: false
    property string notesSaveError: ""
    property bool generatedRefreshBusy: false
    property string generatedRefreshError: ""
    property bool performanceBusy: false
    property string performanceError: ""
    property string performanceProcessError: ""
    property string performanceRaw: ""
    property bool performanceOutputFinished: false
    property bool performanceProcessExited: false
    property bool performanceStderrFinished: false
    property int performanceExitCode: 0
    property int performanceExitStatus: 0
    property string notesProcessError: ""
    property string generatedProcessError: ""
    property bool notesExited: false
    property bool notesErrorFinished: false
    property int notesExitCode: 0
    property int notesExitStatus: 0
    property bool generatedExited: false
    property bool generatedErrorFinished: false
    property int generatedExitCode: 0
    property int generatedExitStatus: 0
    property bool powerBusy: false
    property string powerError: ""
    property string powerProcessError: ""
    property bool powerProcessExited: false
    property bool powerStderrFinished: false
    property int powerExitCode: 0
    property int powerExitStatus: 0

    signal controlRefreshRequested()
    signal performanceRefreshRequested()
    signal todoRefreshRequested()
    signal powerFinished(bool success)

    function actionResult(ok, code, message, data) {
        return {version: 1, ok: ok, code: code, message: message, data: data};
    }

    function accepted(operation) {
        return actionResult(true, "pending", "", {operation: operation, pending: true, observedAtMs: Date.now()});
    }

    function completed(operation, exitCode, exitStatus, message) {
        const code = exitStatus !== 0 ? "failed" : exitCode === 0 ? "ok" :
            exitCode === 75 ? "busy" : exitCode === 124 ? "timeout" :
            exitCode === 4 || exitCode === 126 ? "permission-denied" :
            exitCode === 3 || exitCode === 127 ? "unavailable" : exitCode === 2 ? "invalid-data" : "failed";
        return actionResult(code === "ok", code, code === "ok" ? "" : message,
            {operation: operation, pending: false, observedAtMs: Date.now(), exitCode: exitCode});
    }

    function runCaffeine(mode) {
        if (["off", "30m", "1h", "indefinite"].indexOf(mode) < 0)
            return caffeineResult = actionResult(false, "invalid-data", "Unknown Awake mode", null);
        if (caffeineBusy)
            return caffeineResult = actionResult(false, "busy", "An Awake change is already in progress", null);
        caffeineBusy = true;
        caffeineRaw = "";
        caffeineExited = false;
        caffeineOutputFinished = false;
        caffeineResult = accepted("caffeine");
        caffeineRevision += 1;
        caffeineProcess.command = ["timeout", "15s", scriptRoot + "/status/caffeine.sh", "action", mode];
        caffeineProcess.running = true;
        return caffeineResult;
    }

    function finishCaffeine() {
        if (!caffeineExited || !caffeineOutputFinished)
            return;
        try {
            const reply = JSON.parse(caffeineRaw);
            if (reply.version !== 1 || typeof reply.ok !== "boolean" || typeof reply.code !== "string" || typeof reply.message !== "string" ||
                    Object.keys(reply).sort().join("|") !== "code|data|message|ok|version" ||
                    (reply.ok === true && (caffeineExitCode !== 0 || caffeineExitStatus !== 0)))
                throw new Error("invalid Awake response");
            caffeineResult = reply;
        } catch (error) {
            caffeineResult = caffeineExitCode === 0 && caffeineExitStatus === 0
                ? actionResult(false, "invalid-data", "Awake control returned invalid action data", null)
                : completed("caffeine", caffeineExitCode, caffeineExitStatus, "The Awake change did not finish");
        }
        caffeineBusy = false;
        caffeineRevision += 1;
        controlRefreshRequested();
    }

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

        const caffeinePrefix = scriptRoot + "/status/caffeine.sh ";
        if (command.indexOf(caffeinePrefix) === 0)
            return runCaffeine(command.slice(caffeinePrefix.length));
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
        if (performanceBusy)
            return performanceResult = actionResult(false, "busy", "A performance change is already in progress", null);
        if (command.length === 0)
            return performanceResult = actionResult(false, "invalid-data", "No performance action was selected", null);

        performanceProcessError = "";
        performanceRaw = "";
        performanceOutputFinished = false;
        performanceProcessExited = false;
        performanceStderrFinished = false;
        performanceError = "";
        performanceBusy = true;
        performanceProcess.command = ["timeout", "45s", "sh", "-c", command];
        performanceResult = accepted("performance");
        performanceProcess.running = true;
        return performanceResult;
    }

    function runPower(command) {
        if (powerBusy || powerProcess.running)
            return powerResult = actionResult(false, "busy", "A power action is already in progress", null);
        if (command.length === 0)
            return powerResult = actionResult(false, "invalid-data", "No power action was selected", null);

        powerProcessError = "";
        powerError = "";
        powerProcessExited = false;
        powerStderrFinished = false;
        powerBusy = true;
        powerProcess.command = ["timeout", "90s", "sh", "-c", command];
        powerResult = accepted("power");
        powerProcess.running = true;
        return powerResult;
    }

    function finishPower() {
        if (!powerProcessExited || !powerStderrFinished)
            return;

        powerBusy = false;
        const message = powerProcessError.trim().length > 0
            ? errorMessage("Power action failed", powerExitCode, powerProcessError)
            : powerExitCode === 124 ? "Power action timed out" : "Power action failed (exit " + powerExitCode + ")";
        powerResult = completed("power", powerExitCode, powerExitStatus, message);
        powerError = powerResult.ok ? "" : powerResult.message;
        powerFinished(powerResult.ok);
    }

    function finishPerformance() {
        if (!performanceProcessExited || !performanceStderrFinished || !performanceOutputFinished)
            return ;

        performanceBusy = false;
        if (performanceExitCode !== 0 || performanceExitStatus !== 0)
            performanceError = errorMessage("Performance action failed", performanceExitCode, performanceProcessError);

        performanceResult = completed("performance", performanceExitCode, performanceExitStatus, performanceError);
        if (performanceRaw.trim().length > 0) {
            try {
                const reply = JSON.parse(performanceRaw);
                if (reply.version !== 1 || typeof reply.ok !== "boolean" || typeof reply.code !== "string" ||
                        typeof reply.message !== "string" || Object.keys(reply).sort().join("|") !== "code|data|message|ok|version" ||
                        (reply.ok && (performanceExitCode !== 0 || performanceExitStatus !== 0)))
                    throw new Error("invalid performance response");
                performanceResult = reply;
                performanceError = reply.ok ? "" : reply.message;
            } catch (error) {
                if (performanceExitCode === 0 && performanceExitStatus === 0) {
                    performanceResult = actionResult(false, "invalid-data", "Performance control returned invalid action data", null);
                    performanceError = performanceResult.message;
                }
            }
        }
        controlRefreshRequested();
        performanceRefreshRequested();
    }

    function saveNotes(file, body) {
        if (notesSaveBusy) {
            notesSaveError = "A note is already being saved.";
            return notesSaveResult = actionResult(false, "busy", notesSaveError, null);
        }
        if (file.length === 0) {
            notesSaveError = "No note file is selected.";
            return notesSaveResult = actionResult(false, "invalid-data", notesSaveError, null);
        }
        notesProcessError = "";
        notesExited = false;
        notesErrorFinished = false;
        notesSaveError = "";
        notesSaveBusy = true;
        notesProcess.command = [scriptRoot + "/todo/save.py", file, body];
        notesSaveResult = accepted("save-notes");
        notesProcess.running = true;
        return notesSaveResult;
    }

    function refreshGeneratedNotes() {
        if (generatedRefreshBusy) {
            generatedRefreshError = "Generated notes are already being refreshed.";
            return generatedRefreshResult = actionResult(false, "busy", generatedRefreshError, null);
        }
        generatedProcessError = "";
        generatedExited = false;
        generatedErrorFinished = false;
        generatedRefreshError = "";
        generatedRefreshBusy = true;
        generatedProcess.command = ["timeout", "90s", scriptRoot + "/todo/generated-refresh.sh"];
        generatedRefreshResult = accepted("refresh-generated-notes");
        generatedProcess.running = true;
        return generatedRefreshResult;
    }

    function finishNotes() {
        if (!notesExited || !notesErrorFinished)
            return;
        notesSaveBusy = false;
        notesSaveResult = completed("save-notes", notesExitCode, notesExitStatus,
            errorMessage("Could not save the note", notesExitCode, notesProcessError));
        notesSaveError = notesSaveResult.message;
        if (notesSaveResult.ok)
            notesSaveRevision += 1;
        todoRefreshRequested();
    }

    function finishGenerated() {
        if (!generatedExited || !generatedErrorFinished)
            return;
        generatedRefreshBusy = false;
        generatedRefreshResult = completed("refresh-generated-notes", generatedExitCode, generatedExitStatus,
            generatedExitCode === 75 ? "Generated notes are already being refreshed." :
            errorMessage("Could not refresh generated notes", generatedExitCode, generatedProcessError));
        generatedRefreshError = generatedRefreshResult.message;
        todoRefreshRequested();
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
        objectName: "performance-action-process"

        onExited: (exitCode, exitStatus) => {
            root.performanceExitCode = exitCode;
            root.performanceExitStatus = exitStatus;
            root.performanceProcessExited = true;
            root.finishPerformance();
        }

        stdout: StdioCollector {
            onStreamFinished: {
                root.performanceRaw = this.text;
                root.performanceOutputFinished = true;
                root.finishPerformance();
            }
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
        objectName: "notes-save-process"
        onExited: (exitCode, exitStatus) => {
            root.notesExitCode = exitCode;
            root.notesExitStatus = exitStatus;
            root.notesExited = true;
            root.finishNotes();
        }
        stderr: StdioCollector {
            onStreamFinished: {
                root.notesProcessError = this.text;
                root.notesErrorFinished = true;
                root.finishNotes();
            }
        }
    }

    Process {
        id: generatedProcess
        objectName: "generated-refresh-process"
        onExited: (exitCode, exitStatus) => {
            root.generatedExitCode = exitCode;
            root.generatedExitStatus = exitStatus;
            root.generatedExited = true;
            root.finishGenerated();
        }
        stderr: StdioCollector {
            onStreamFinished: {
                root.generatedProcessError = this.text;
                root.generatedErrorFinished = true;
                root.finishGenerated();
            }
        }
    }

    Process {
        id: powerProcess
        objectName: "power-action-process"
        onExited: (exitCode, exitStatus) => {
            root.powerExitCode = exitCode;
            root.powerExitStatus = exitStatus;
            root.powerProcessExited = true;
            root.finishPower();
        }
        stderr: StdioCollector {
            onStreamFinished: {
                root.powerProcessError = this.text;
                root.powerStderrFinished = true;
                root.finishPower();
            }
        }
    }

    Process {
        id: caffeineProcess
        objectName: "caffeine-action-process"
        onExited: (exitCode, exitStatus) => {
            root.caffeineExitCode = exitCode;
            root.caffeineExitStatus = exitStatus;
            root.caffeineExited = true;
            root.finishCaffeine();
        }
        stdout: StdioCollector {
            onStreamFinished: {
                root.caffeineRaw = this.text;
                root.caffeineOutputFinished = true;
                root.finishCaffeine();
            }
        }
    }

}
