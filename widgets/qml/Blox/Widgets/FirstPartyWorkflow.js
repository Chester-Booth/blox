.pragma library

// Only these fixed operations may outlive their visible producer subscription.
function operation(binding) {
    if (!binding || binding.kind !== "run" || !Array.isArray(binding.command)
            || binding.command.length !== 3 || binding.command[0] !== "blox-widget-action"
            || !Number.isFinite(binding.timeoutSeconds) || binding.timeoutSeconds < 0.01
            || binding.timeoutSeconds > 120) return "";
    if (binding.command[1] === "todo" && binding.command[2] === "edit") return "todo";
    if (binding.command[1] === "calendar" && binding.command[2] === "open") return "calendar";
    return "";
}

function cap(binding) {
    return Math.min(binding.timeoutSeconds, operation(binding) === "todo" ? 10 : 120);
}
