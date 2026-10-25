var wasmExports = null;

WebAssembly.instantiateStreaming(fetch("pgen-bridge.wasm")).then(
    (result) => {
        wasmExports = result.instance.exports;
    },
);

function backendParse(input, cstOwnsToken) {
    err = (message) => ({
        stderrText: message,
        stdoutText: "",
    });
    if (!/^[\x00-\x7F]*$/.test(input))
        return err("ASCII only please");
    if (wasmExports == null)
        return err("Loading... Try again later");
    if (input == "")
        return err("Type something...");
    const {
        memory, pgenParse, newMessagePtr,
        releaseMessage, newBuffer, freeBuffer,
        messagePtr, messageLen, invalidPtr,
    } = wasmExports;
    const nullPtr = invalidPtr();
    const inLen = input.length;
    const inBuffer = newBuffer(inLen);
    if (inBuffer == nullPtr)
        return err("Out of memory");
    const stderr = newMessagePtr();
    const stdout = newMessagePtr();
    if (stderr == nullPtr || stdout == nullPtr) {
        freeBuffer(inBuffer, inLen);
        return err("Out of memory");
    }
    new TextEncoder().encodeInto(input, new Uint8Array(memory.buffer, inBuffer, inLen));
    pgenParse(inBuffer, inLen, stderr, stdout, cstOwnsToken);
    freeBuffer(inBuffer, inLen);

    obtainMessage = (msg) => new TextDecoder().decode(new Uint8Array(
        memory.buffer, messagePtr(msg), messageLen(msg)
    ));

    const stderrText = obtainMessage(stderr);
    const stdoutText = obtainMessage(stdout);
    releaseMessage(stderr);
    releaseMessage(stdout);
    return {stderrText, stdoutText};
}

document.addEventListener('DOMContentLoaded', () => {
    const inputSource = document.getElementById("input-source");
    const cstOwnsToken = document.getElementById("cst-owns-token");
    const stderrBox = document.getElementById("output-stderr");
    const stdoutBox = document.getElementById("output-stdout");
    let debounceTimer = null;
    function goParse() {
        const {stderrText, stdoutText} = backendParse(inputSource.value, cstOwnsToken.checked);
        stderrBox.textContent = (stderrText.length > 0) ? stderrText : "(no error)";
        stdoutBox.textContent = (stdoutText.length > 0) ? stdoutText : "(no output)";
    }
    function onInputChanged() {
        if (debounceTimer != null)
            clearTimeout(debounceTimer);
        debounceTimer = setTimeout(goParse, 500);
    }
    inputSource.addEventListener('input', onInputChanged);
    cstOwnsToken.addEventListener('change', onInputChanged);
});
