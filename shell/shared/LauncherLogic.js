.pragma library

function normaliseId(value) {
    return String(value || "").toLowerCase().replace(/\.desktop$/, "");
}

function looksLikeCalculation(value) {
    const text = String(value || "").trim();
    if (!text.match(/\d/))
        return false;
    if (/^(?:[$£€¥]\s*[0-9]+(?:\.[0-9]+)?|[0-9]+(?:\.[0-9]+)?\s*(?:[$£€¥]|[a-zA-Z°]+))\s=\s(?:[$£€¥]|[a-zA-Z°]+)$/.test(text))
        return true;
    if (/^[\d\s.,()+\-*/^%!]+$/.test(text) && /[+\-*/^%!]/.test(text))
        return true;
    if (/\b(to|in)\b/i.test(text))
        return true;
    if (/[$£€¥]/.test(text))
        return true;
    return /^\d+(?:\.\d+)?\s*(?:mm|cm|m|km|in|ft|yd|mi|mg|g|kg|oz|lb|ml|l|°c|°f|k|s|min|h|hz|kb|mb|gb|tb)$/i.test(text);
}

function qalcQuery(value) {
    const text = String(value || "").trim();
    const match = text.match(/^((?:[$£€¥]\s*[0-9]+(?:\.[0-9]+)?|[0-9]+(?:\.[0-9]+)?\s*(?:[$£€¥]|[a-zA-Z°]+)))\s=\s((?:[$£€¥]|[a-zA-Z°]+))$/);
    return match ? match[1] + " to " + match[2] : text;
}
